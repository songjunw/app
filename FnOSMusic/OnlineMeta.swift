import Foundation

/// 在线元数据抓取（复刻安卓 OnlineMeta）：
/// 歌词主源 lrclib，中文回退 lyrics.ovh；封面走 iTunes Search API。
/// 结果回传给 player.html 的 window.onMeta(idx, meta)。
struct MetaResult {
    var title: String
    var artist: String
    var album: String
    var cover: String?
    var lyrics: String?
    var timed: [[Any]]?   // [timeSec, text]，逐行高亮用
}

enum OnlineMeta {

    static func fetch(title: String, artist: String) async -> MetaResult? {
        var result = MetaResult(title: title, artist: artist, album: "", cover: nil, lyrics: nil, timed: nil)

        // 歌词：先 lrclib（带时间戳），回退 lyrics.ovh（纯文本）
        if let lrc = await lrclib(title: title, artist: artist) {
            if let timed = parseLRC(lrc) {
                result.timed = timed
                result.lyrics = lrc
            } else {
                result.lyrics = lrc
            }
        } else if let lrc = await lyricsOvh(title: title, artist: artist) {
            result.lyrics = lrc
        }

        // 封面：iTunes Search
        if let cover = await itunesCover(title: title, artist: artist) {
            result.cover = cover
        }

        return (result.lyrics != nil || result.cover != nil) ? result : nil
    }

    // ---------- lrclib ----------
    private static func lrclib(title: String, artist: String) async -> String? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist.isEmpty ? nil : artist),
        ]
        guard let url = comps.url else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first else { return nil }
            // 优先带时间戳的 syncedLyrics
            if let synced = first["syncedLyrics"] as? String, !synced.isEmpty { return synced }
            if let plain = first["plainLyrics"] as? String, !plain.isEmpty { return plain }
        } catch { }
        return nil
    }

    // ---------- lyrics.ovh（中文回退） ----------
    private static func lyricsOvh(title: String, artist: String) async -> String? {
        let a = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let t = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(t)") else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrc = obj["lyrics"] as? String, !lrc.isEmpty else { return nil }
            return lrc
        } catch { }
        return nil
    }

    // ---------- iTunes 封面 ----------
    private static func itunesCover(title: String, artist: String) async -> String? {
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return nil }
        let term = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url else { return nil }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]],
                  let first = results.first,
                  let art = first["artworkUrl100"] as? String else { return nil }
            // 拿大图：把 100x100 换成 600x600
            return art.replacingOccurrences(of: "100x100", with: "600x600")
        } catch { }
        return nil
    }

    // ---------- LRC 解析 ----------
    private static func parseLRC(_ lrc: String) -> [[Any]]? {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var out: [[Any]] = []
        for line in lrc.components(separatedBy: "\n") {
            let ns = line as NSString
            let ms = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !ms.isEmpty else { continue }
            let text = ns.substring(from: ms[0].range(at: 0).upperBound).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for m in ms {
                let min = (m.range(at: 1).location != NSNotFound)
                    ? Int(ns.substring(with: m.range(at: 1))) ?? 0 : 0
                let sec = (m.range(at: 2).location != NSNotFound)
                    ? Int(ns.substring(with: m.range(at: 2))) ?? 0 : 0
                let fracStr = (m.range(at: 3).location != NSNotFound)
                    ? ns.substring(with: m.range(at: 3)) : "0"
                let frac = (Double("0." + fracStr) ?? 0)
                let time = Double(min * 60 + sec) + frac
                out.append([time, text])
            }
        }
        return out.isEmpty ? nil : out
    }
}
