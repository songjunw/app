import Foundation

/// 一次完整的曲库同步：登录飞牛 → 递归扫描音乐目录 → 批量取签名直链 → 写入 Store。
/// 复刻安卓 SyncManager，全程用 FnosClient（WebSocket 中继协议）。
enum SyncManager {

    struct Result {
        var ok: Bool
        var count: Int
        var msg: String
        var expireAt: TimeInterval = 0
    }

    private static let audioExts = Set(["mp3", "flac", "wav", "m4a", "aac", "ogg", "ape", "wma", "opus", "alac"])
    private static let batch = 40
    private static let maxDirs = 4000

    private class Entry {
        var path = ""
        var name = ""
        var album = ""
        var ext = ""
        var size: Int64 = 0
        var uri = ""
        var lrcPath: String?
        var lrc = ""
    }

    static func sync(creds: Creds, onProgress: @escaping (String) -> Void) async -> Result {
        guard creds.valid() else {
            return Result(ok: false, count: 0, msg: "账号信息不完整")
        }
        var res = Result(ok: false, count: 0, msg: "")
        var main: FnosClient? = nil
        var fc: FnosClient? = nil
        do {
            let origin = normOrigin(creds.origin)
            onProgress("正在连接 \(hostOf(origin)) …")
            main = FnosClient(origin: origin)
            try await main!.connect(type: "main")
            try await main!.fetchPub()
            onProgress("正在登录 …")
            try await main!.login(user: creds.user, password: creds.pass, deviceName: "iOS-Player")

            let token = main!.getToken()
            let cookie = "language=zh-CN; mode=relay; fnos-token=\(token)"
            onProgress("正在建立文件通道 …")
            fc = FnosClient(origin: origin, cookie: cookie)
            fc!.setHmacKey(main!.getHmacKey())
            try await fc!.connect(type: "file")
            try await fc!.fetchSI()
            try await fc!.authToken(token)

            let root = normPath(creds.root)
            onProgress("正在扫描 \(root) …")

            var list: [Entry] = []
            var lrcByKey: [String: String] = [:]
            var lrcByPath: [String: Entry] = [:]
            var dirs = 0
            var stack: [String] = [root]
            while !stack.isEmpty {
                let dir = stack.removeLast()
                if dirs + 1 > maxDirs { break }
                dirs += 1
                let items: [[String: Any]]
                do {
                    items = try await fc!.ls(dir)
                } catch {
                    if dirs == 1 {
                        throw NSError(domain: "sync", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "无法打开目录 \(dir)。\(await suggest(fc: fc!, bad: dir))"])
                    }
                    continue
                }
                for it in items {
                    guard let name = it["name"] as? String, !name.isEmpty else { continue }
                    if (it["dir"] as? Int) == 1 {
                        stack.append(dir + "/" + name)
                        continue
                    }
                    guard let dot = name.lastIndex(of: ".") else { continue }
                    let ext = String(name[name.index(after: dot)...]).lowercased()
                    if ext == "lrc" {
                        let base = String(name[..<dot])
                        let album = dir.count > root.count
                            ? String(dir[dir.index(root.endIndex, offsetBy: 1)...]) : ""
                        lrcByKey[lrcKey(album: album, base: base)] = dir + "/" + name
                        let nb = normBase(base)
                        if nb != base { lrcByKey[lrcKey(album: album, base: nb)] = dir + "/" + name }
                        continue
                    }
                    guard audioExts.contains(ext) else { continue }
                    let e = Entry()
                    e.path = dir + "/" + name
                    e.name = name
                    e.ext = ext
                    e.size = (it["size"] as? NSNumber)?.int64Value ?? 0
                    e.album = dir.count > root.count
                        ? String(dir[dir.index(root.endIndex, offsetBy: 1)...]) : ""
                    list.append(e)
                }
                if dirs % 5 == 0 || list.count % 200 == 0 {
                    onProgress("已扫描 \(dirs) 个目录，找到 \(list.count) 首 …")
                }
            }

            // 把扫描到的 .lrc 关联到对应音频
            for e in list {
                guard let dot = e.name.lastIndex(of: ".") else { continue }
                let base = String(e.name[..<dot])
                var lrcPath = lrcByKey[lrcKey(album: e.album, base: base)]
                if lrcPath == nil {
                    let nb = normBase(base)
                    if nb != base { lrcPath = lrcByKey[lrcKey(album: e.album, base: nb)] }
                }
                if let lp = lrcPath {
                    e.lrcPath = lp
                    lrcByPath[lp] = e
                }
            }
            if list.isEmpty {
                throw NSError(domain: "sync", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "目录 \(root) 下没有找到音频文件，请检查路径"])
            }
            onProgress("共 \(list.count) 首，正在获取播放链接 …")

            // 中文友好排序：先目录后文件名
            list.sort {
                let c = $0.album.localizedCompare($1.album)
                if c != .orderedSame { return c == .orderedAscending }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }

            // 批量取签名直链
            var got = 0
            for i in stride(from: 0, to: list.count, by: batch) {
                let end = min(i + batch, list.count)
                let paths = (i..<end).map { list[$0].path }
                let uris = try await fc!.download(paths)
                for k in 0..<(end - i) {
                    if k < uris.count,
                       let u = uris[k]["uri"] as? String, !u.isEmpty {
                        list[i + k].uri = u
                        got += 1
                    }
                }
                if (i / batch) % 3 == 0 {
                    onProgress("获取链接 \(end)/\(list.count) …")
                }
            }
            if got == 0 {
                throw NSError(domain: "sync", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "未能获取任何播放链接"])
            }

            // 批量取同名 .lrc 歌词直链
            if !lrcByPath.isEmpty {
                let lrcPaths = Array(lrcByPath.keys)
                var lgot = 0
                for i in stride(from: 0, to: lrcPaths.count, by: batch) {
                    let end = min(i + batch, lrcPaths.count)
                    let slice = Array(lrcPaths[i..<end])
                    let uris = try await fc!.download(slice)
                    for k in 0..<slice.count {
                        if k < uris.count,
                           let u = uris[k]["uri"] as? String, !u.isEmpty,
                           let e = lrcByPath[slice[k]] {
                            e.lrc = u
                            lgot += 1
                        }
                    }
                }
                onProgress("已关联 \(lgot) 个歌词文件")
            }

            // 生成清单并写入
            var arr: [[String: Any]] = []
            for e in list {
                guard !e.uri.isEmpty else { continue }
                arr.append([
                    "name": e.name, "album": e.album, "ext": e.ext,
                    "size": e.size, "uri": e.uri, "lrc": e.lrc,
                ])
            }
            let iso = isoNow()
            let playlist: [String: Any] = ["origin": origin, "generatedAt": iso, "tracks": arr]
            let config: [String: Any] = ["origin": origin, "cookie": cookie, "syncedAt": iso]
            guard let plData = try? JSONSerialization.data(withJSONObject: playlist),
                  let cfgData = try? JSONSerialization.data(withJSONObject: config),
                  let plStr = String(data: plData, encoding: .utf8),
                  let cfgStr = String(data: cfgData, encoding: .utf8) else {
                throw NSError(domain: "sync", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "生成清单失败"])
            }
            let n = try Store.shared.importPlaylist(plStr, configJson: cfgStr)
            creds.save()

            res.ok = true
            res.count = n
            res.expireAt = Store.shared.expireAt
            res.msg = "已同步 \(n) 首"
            if got < list.count {
                res.msg += "（\(list.count - got) 首未取到链接）"
            }
        } catch {
            res.ok = false
            res.msg = error.localizedDescription
        }
        main?.close()
        fc?.close()
        return res
    }

    // ---------- 路径/字符串工具（复刻安卓版） ----------

    /// 规范化飞牛地址。把 `https://5ddd.com/s3664849639` 换算成 `https://s3664849639.5ddd.com`；
    /// 局域网地址（带端口）原样返回。
    static func normOrigin(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        let low = s.lowercased()
        if !low.hasPrefix("http://") && !low.hasPrefix("https://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let p = s.range(of: "://") else { return s }
        let scheme = String(s[..<p.upperBound])
        let rest = String(s[p.upperBound...])
        guard let slash = rest.firstIndex(of: "/") else { return scheme + rest }
        let host = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        if host.contains(":") { return scheme + rest }
        if path.isEmpty || path.contains("/") || path.contains("?") { return scheme + rest }
        return scheme + path + "." + host
    }

    static func hostOf(_ origin: String) -> String {
        guard let p = origin.range(of: "://") else { return origin }
        let h = String(origin[p.upperBound...])
        if let s = h.firstIndex(of: "/") { return String(h[..<s]) }
        return h
    }

    private static func lrcKey(album: String, base: String) -> String {
        return (album.isEmpty ? "" : album) + "/" + (base.isEmpty ? "" : base)
    }

    /// 去掉文件名开头的音轨号："01. 晴天" / "01 - 晴天" -> "晴天"
    private static func normBase(_ base: String) -> String {
        var s = base.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}[\.\、\s\-_]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// 去掉首尾斜杠，路径形如 vol1/1000/音乐
    private static func normPath(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func isoNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    /// 路径打不开时，往上层找一层能打开的目录，列出里面有什么，方便用户改对
    private static func suggest(fc: FnosClient, bad: String) async -> String {
        var p = bad
        for _ in 0..<3 {
            guard let slash = p.lastIndex(of: "/") else { break }
            p = String(p[..<slash])
            do {
                let items = try await fc.ls(p)
                var sb: [String] = []
                for it in items {
                    if (it["dir"] as? Int) == 1, let name = it["name"] as? String {
                        sb.append(name)
                        if sb.count >= 8 { break }
                    }
                }
                if !sb.isEmpty { return "\(p) 下可用目录：" + sb.joined(separator: " / ") }
            } catch { }
        }
        return "请检查路径格式，通常形如 vol1/1000/音乐"
    }
}
