import Foundation

/// 在线封面抓取（iTunes Search API）。
///
/// 说明：歌词功能已按需求移除，不再请求 lrclib / lyrics.ovh，也不做 LRC 解析。
/// 结果回传给 player.html 的 window.onMeta(idx, meta)。
struct MetaResult {
    var title: String
    var artist: String
    var album: String
    var cover: String?
}

enum OnlineMeta {

    static func fetch(title: String, artist: String) async -> MetaResult? {
        var result = MetaResult(title: title, artist: artist, album: "", cover: nil)
        if let cover = await itunesCover(title: title, artist: artist) {
            result.cover = cover
        }
        return result.cover != nil ? result : nil
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
}
