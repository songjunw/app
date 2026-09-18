import Foundation

/// 单首曲目（对齐安卓 Store.Track）
struct StoredTrack {
    var idx: Int
    var name: String      // 文件名
    var title: String     // 去扩展名后的显示名
    var album: String     // 所属子目录，空串表示根目录
    var ext: String
    var size: Int64
    var uri: String       // /download/... 带签名的相对路径（原生层拼 origin 后由 AVPlayer 播放）
    var lrc: String       // 同名 .lrc 歌词文件的签名直链（没有则为空串）
}

/// 清单与凭据存储（复刻安卓 Store）。
/// 优先读 App 沙盒内导入的 playlist.json / config.json，回退到内置（iOS 暂无内置）。
/// 用串行队列保护并发读写，保证播放中读取与后台同步写入不撞车。
final class Store {
    static let shared = Store()

    private let fm = FileManager.default
    private let dir: URL
    private let queue = DispatchQueue(label: "com.fnos.store")

    private var _origin = ""
    private var _cookie = ""
    private var _syncedAt = ""
    private var _generatedAt = ""
    private var _tracks: [StoredTrack] = []
    private var _albums: [String] = []
    private var _expireAt: TimeInterval = 0
    private var _loadSource = "none"

    private init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("fnos", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // 同步访问器
    var tracks: [StoredTrack] { queue.sync { _tracks } }
    var albums: [String] { queue.sync { _albums } }
    var origin: String { queue.sync { _origin } }
    var cookie: String { queue.sync { _cookie } }
    var expireAt: TimeInterval { queue.sync { _expireAt } }
    var syncedAt: String { queue.sync { _syncedAt } }
    var generatedAt: String { queue.sync { _generatedAt } }
    var loadSource: String { queue.sync { _loadSource } }

    func track(at idx: Int) -> StoredTrack? {
        queue.sync { idx >= 0 && idx < _tracks.count ? _tracks[idx] : nil }
    }

    /// 距签名过期还剩多少小时；未知返回 -1
    func hoursLeft() -> Double {
        let e = expireAt
        if e <= 0 { return -1 }
        return (e * 1000 - Date().timeIntervalSince1970 * 1000) / 3600000
    }

    func totalBytes() -> Int64 {
        queue.sync { _tracks.reduce(0) { $0 + $1.size } }
    }

    // ---------- 收藏（UserDefaults） ----------
    private let favKey = "fnos_favs"
    func getFavs() -> [Int] {
        let s = UserDefaults.standard.string(forKey: favKey) ?? "[]"
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Int] else { return [] }
        return arr
    }
    func isFav(_ idx: Int) -> Bool { getFavs().contains(idx) }
    @discardableResult func toggleFav(_ idx: Int) -> Bool {
        var f = getFavs()
        let now: Bool
        if let i = f.firstIndex(of: idx) { f.remove(at: i); now = false }
        else { f.append(idx); now = true }
        if let data = try? JSONSerialization.data(withJSONObject: f),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: favKey)
        }
        return now
    }

    /// 退出登录时清空同步清单（删除文件 + 重置内存中的曲库）
    func clearPlaylist() {
        queue.sync {
            _origin = ""; _cookie = ""; _syncedAt = ""; _generatedAt = ""
            _tracks = []; _albums = []; _expireAt = 0; _loadSource = "none"
        }
        try? fm.removeItem(at: dir.appendingPathComponent("playlist.json"))
        try? fm.removeItem(at: dir.appendingPathComponent("config.json"))
    }

    /// 直接设置某首收藏状态（与 AppShim 本地乐观更新保持一致，由原生持久化）
    func setFav(_ idx: Int, _ on: Bool) {
        var f = getFavs()
        if on { if !f.contains(idx) { f.append(idx) } }
        else { f.removeAll { $0 == idx } }
        if let data = try? JSONSerialization.data(withJSONObject: f),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: favKey)
        }
    }

    // ---------- 加载 ----------
    func load() {
        queue.sync {
            _origin = ""; _cookie = ""; _syncedAt = ""; _generatedAt = ""; _expireAt = 0
            _loadSource = "none"
            if let cfg = readFile("config.json"),
               let o = try? JSONSerialization.jsonObject(with: Data(cfg.utf8)) as? [String: Any] {
                _origin = o["origin"] as? String ?? ""
                _cookie = o["cookie"] as? String ?? ""
                _syncedAt = o["syncedAt"] as? String ?? ""
            }
            if let pl = readFile("playlist.json") {
                parsePlaylist(pl); _loadSource = "internal"
            }
        }
    }

    /// 用同步生成的清单覆盖，返回条目数；失败抛错
    @discardableResult
    func importPlaylist(_ playlistJson: String, configJson: String?) throws -> Int {
        guard let data = playlistJson.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["tracks"] as? [[String: Any]],
              !arr.isEmpty else {
            throw NSError(domain: "store", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "清单里没有 tracks"])
        }
        if let cfg = configJson, !cfg.isEmpty {
            _ = try? JSONSerialization.jsonObject(with: Data(cfg.utf8))
            writeFile("config.json", cfg)
        }
        writeFile("playlist.json", playlistJson)
        queue.sync { parsePlaylist(playlistJson) }
        return arr.count
    }

    private func parsePlaylist(_ json: String) {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if _origin.isEmpty { _origin = root["origin"] as? String ?? "" }
        _generatedAt = root["generatedAt"] as? String ?? ""
        guard let arr = root["tracks"] as? [[String: Any]] else { return }
        var newTracks: [StoredTrack] = []
        var albumSeen: [String: Int] = [:]
        for t in arr {
            var k = StoredTrack(idx: newTracks.count,
                          name: t["name"] as? String ?? "",
                          title: "",
                          album: t["album"] as? String ?? "",
                          ext: t["ext"] as? String ?? "",
                          size: (t["size"] as? NSNumber)?.int64Value ?? 0,
                          uri: t["uri"] as? String ?? "",
                          lrc: t["lrc"] as? String ?? "")
            if let dot = k.name.lastIndex(of: ".") {
                k.title = String(k.name[..<dot])
            } else {
                k.title = k.name
            }
            newTracks.append(k)
            if albumSeen[k.album] == nil { albumSeen[k.album] = 1 }
        }
        _tracks = newTracks
        _albums = Array(albumSeen.keys)
        if !newTracks.isEmpty {
            let u = newTracks[0].uri
            if let p = u.range(of: "t=") {
                let tail = u[u.index(p.lowerBound, offsetBy: 2)...]
                let v = tail.split(separator: "&").first.map(String.init) ?? String(tail)
                _expireAt = TimeInterval(v) ?? 0
            }
        }
    }

    /// 给 player.html 的 App.getPlaylist() 用：返回 {origin, generatedAt, tracks:[...]}
    func getPlaylistJSONString() -> String {
        queue.sync {
            var arr: [[String: Any]] = []
            for t in _tracks {
                arr.append([
                    "name": t.name, "title": t.title, "album": t.album,
                    "ext": t.ext, "size": t.size, "uri": t.uri, "lrc": t.lrc,
                ])
            }
            let root: [String: Any] = [
                "origin": _origin, "generatedAt": _generatedAt, "tracks": arr,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: root),
               let s = String(data: data, encoding: .utf8) { return s }
            return "{\"tracks\":[]}"
        }
    }

    // ---------- io ----------
    private func readFile(_ name: String) -> String? {
        let p = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: p.path) else { return nil }
        return try? String(contentsOf: p, encoding: .utf8)
    }
    private func writeFile(_ name: String, _ content: String) {
        let p = dir.appendingPathComponent(name)
        try? content.write(to: p, atomically: true, encoding: .utf8)
    }
}
