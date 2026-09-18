import UIKit
import WebKit

/// WebView 壳：加载复用安卓版的 player.html，通过注入的 window.App 桥接与原生引擎通讯。
/// 原生层承载：NAS 登录同步（SyncManager）、播放（AudioEngine）、在线元数据（OnlineMeta）、存储（Store/Creds）。
final class ViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, AudioEngineDelegate {

    private var webView: WKWebView!
    private let engine = AudioEngine()
    private var tracks: [Track] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        loadTracksFromStore()
        engine.tracks = tracks

        let ctrl = WKUserContentController()
        let userScript = WKUserScript(source: shimScript(),
                                     injectionTime: .atDocumentStart,
                                     forMainFrameOnly: true)
        ctrl.addUserScript(userScript)
        ctrl.add(self, name: "App")

        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ctrl
        cfg.allowsInlineMediaPlayback = true
        if #available(iOS 15.0, *) {
            cfg.mediaTypesRequiringUserActionForPlayback = []
        }

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        view.addSubview(webView)
        engine.delegate = self

        if let url = Bundle.main.url(forResource: "player", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }
    }

    // MARK: - 曲库

    private func loadTracksFromStore() {
        let store = Store.shared
        let origin = store.origin
        if !store.tracks.isEmpty {
            tracks = store.tracks.map { st in
                let full = st.uri.hasPrefix("http") ? st.uri : (origin + st.uri)
                let lrc = st.lrc.isEmpty ? "" : (st.lrc.hasPrefix("http") ? st.lrc : (origin + st.lrc))
                return Track(idx: st.idx, title: st.title.isEmpty ? st.name : st.title,
                             album: st.album, url: full, ext: st.ext, size: Int(st.size), lrc: lrc)
            }
        } else {
            tracks = sampleTracks()
        }
    }

    private func sampleTracks() -> [Track] {
        let urls = [
            "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3",
            "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3",
            "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3",
        ]
        let names = ["示例曲目 1", "示例曲目 2", "示例曲目 3"]
        return urls.enumerated().map { i, u in
            Track(idx: i, title: names[i], album: "测试歌单", url: u, ext: "mp3", size: 0, lrc: "")
        }
    }

    // MARK: - 注入全局状态

    private func shimScript() -> String {
        var base = ""
        if let path = Bundle.main.path(forResource: "AppShim", ofType: "js"),
           let s = try? String(contentsOfFile: path, encoding: .utf8) { base = s }
        let store = Store.shared
        let pl = store.tracks.isEmpty ? samplePlaylistJSON() : store.getPlaylistJSONString()
        let js = base +
            "\nwindow.__PLAYLIST__ = \(pl);" +
            "\nwindow.__ACCOUNT__ = \(accountJSON());" +
            "\nwindow.__FAVS__ = \(favsJSON());" +
            "\nwindow.__favIdxs = \(favIdxsJSON());" +
            "\nwindow.__STAT__ = \(statJSON());\n"
        return js
    }

    private func samplePlaylistJSON() -> String {
        let arr = sampleTracks().map { t in
            ["name": t.title, "title": t.title, "album": t.album,
             "ext": t.ext, "size": t.size, "uri": t.url, "lrc": ""] as [String: Any]
        }
        return jsonString(["origin": "", "generatedAt": "", "tracks": arr])
    }

    private func accountJSON() -> String {
        let cr = Creds.load()
        let saved = !cr.origin.isEmpty && !cr.user.isEmpty
        return jsonString(["saved": saved, "origin": cr.origin, "user": cr.user])
    }
    private func favsJSON() -> String { jsonString(["idxs": Store.shared.getFavs()]) }
    private func favIdxsJSON() -> String { jsonString(Store.shared.getFavs()) }
    private func statJSON() -> String {
        let store = Store.shared
        return jsonString([
            "count": store.tracks.count,
            "albums": store.albums.count,
            "hoursLeft": store.hoursLeft(),
            "totalBytes": store.totalBytes(),
        ])
    }

    private func jsonString(_ obj: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }
    /// String -> JS 字符串字面量（带双引号）
    private func jsStr(_ s: String) -> String { jsonString(s) }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let method = body["m"] as? String else { return }
        let args = body["a"] as? [Any] ?? []
        handle(method: method, args: args)
    }

    private func handle(method: String, args: [Any]) {
        switch method {
        case "play":
            if let i = args.first as? Int { engine.playTrack(i) }
        case "toggle": engine.toggle()
        case "next": engine.next(userTriggered: true)
        case "prev": engine.prev()
        case "seek":
            if let ms = args.first as? Int { engine.seek(ms: ms) }
        case "setMode":
            if let m = args.first as? Int { engine.setMode(m) }
        case "setVolume":
            if let v = args.first as? Double { engine.setVolume(Float(v)) }
        case "setQueue":
            if let idxJson = args.first as? String,
               let data = idxJson.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [Int] {
                let start = (args.count > 1 ? (args[1] as? Int) : 0) ?? 0
                engine.setQueue(indices: arr, startPos: start)
            }
        case "requestMeta":
            if let idx = args.first as? Int { requestMeta(idx: idx) }
        case "login":
            if let o = args[0] as? String, let u = args[1] as? String,
               let p = args[2] as? String, let r = args[3] as? String {
                let cr = Creds(origin: o, user: u, pass: p, root: r)
                cr.save()
                runSync()
            }
        case "syncNow":
            runSync()
        case "logout":
            doLogout()
        case "toggleFavorite":
            if let idx = args[0] as? Int, let on = args[1] as? Bool {
                Store.shared.setFav(idx, on)
            } else if let idx = args[0] as? Int {
                Store.shared.toggleFav(idx)
            }
        case "toast":
            break
        default: break
        }
    }

    // MARK: - 同步

    private func runSync() {
        let cr = Creds.load()
        guard cr.valid() else {
            eval("window.onSyncResult && window.onSyncResult({\"ok\":false,\"msg\":\"请先在设置中填写 NAS 账号\"})")
            return
        }
        eval("window.onSyncProgress && window.onSyncProgress(\"准备同步…\")")
        Task {
            let res = await SyncManager.sync(creds: cr) { msg in
                DispatchQueue.main.async {
                    self.eval("window.onSyncProgress && window.onSyncProgress(\(self.jsStr(msg)))")
                }
            }
            await MainActor.run {
                if res.ok {
                    self.loadTracksFromStore()
                    self.engine.tracks = self.tracks
                    self.injectState()
                    self.eval("window.onSyncResult && window.onSyncResult({\"ok\":true,\"msg\":\(self.jsStr(res.msg)),\"count\":\(res.count)})")
                } else {
                    self.eval("window.onSyncResult && window.onSyncResult({\"ok\":false,\"msg\":\(self.jsStr(res.msg))})")
                }
            }
        }
    }

    private func doLogout() {
        Creds.clear()
        Store.shared.clearPlaylist()
        loadTracksFromStore()
        engine.tracks = tracks
        injectState()
        eval("window.onSyncResult && window.onSyncResult({\"ok\":false,\"msg\":\"已退出登录\"})")
    }

    /// 同步/登出后热更新全局变量，player.html 的 boot()/loadAcc() 会读取
    private func injectState() {
        let js = "window.__PLAYLIST__ = \(Store.shared.getPlaylistJSONString());" +
                 "window.__ACCOUNT__ = \(accountJSON());" +
                 "window.__FAVS__ = \(favsJSON());" +
                 "window.__favIdxs = \(favIdxsJSON());" +
                 "window.__STAT__ = \(statJSON());"
        eval(js)
    }

    private func eval(_ js: String) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 在线元数据

    private func requestMeta(idx: Int) {
        guard idx >= 0, idx < tracks.count else { return }
        let t = tracks[idx]
        let title = t.title
        let artist = t.album
        eval("window.onMetaLoading && window.onMetaLoading(\(idx))")
        Task {
            let meta = await OnlineMeta.fetch(title: title, artist: artist)
            await MainActor.run {
                if let meta = meta {
                    let d: [String: Any] = [
                        "artist": meta.artist, "title": meta.title,
                        "cover": meta.cover ?? "", "lyrics": meta.lyrics ?? "",
                        "timed": meta.timed ?? [],
                    ]
                    self.eval("window.onMeta && window.onMeta(\(idx), \(self.jsonString(d)))")
                } else {
                    self.eval("window.onMeta && window.onMeta(\(idx), {})")
                }
            }
        }
    }

    // MARK: - AudioEngineDelegate

    func engineStateChanged() { pushState() }

    func engineProgress(posMs: Int, durMs: Int, bufPct: Int) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(
                "window.onNativeProgress && window.onNativeProgress(\(posMs),\(durMs),\(bufPct))",
                completionHandler: nil)
        }
    }

    private func pushState() {
        DispatchQueue.main.async {
            var d: [String: Any] = [:]
            let t = self.engine.currentTrack
            d["track"] = t?.idx ?? -1
            d["playing"] = self.engine.isPlaying
            d["loading"] = self.engine.isLoading
            d["mode"] = self.engine.mode
            d["dur"] = self.engine.durationMs
            d["pos"] = self.engine.positionMs
            d["err"] = self.engine.errorMsg
            let json = self.jsonString(d)
            self.webView.evaluateJavaScript(
                "window.onNativeState && window.onNativeState(\(json))", completionHandler: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushState()
    }
}
