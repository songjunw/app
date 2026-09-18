import UIKit
import WebKit

/// WebView 壳：加载复用安卓版的 player.html，通过注入的 window.App 桥接与原生引擎通讯。
final class ViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate, AudioEngineDelegate {

    private var webView: WKWebView!
    private let engine = AudioEngine()
    private var tracks: [Track] = []

    /// 测试歌单：使用公开可流式播放的示例音频，验证“安装/播放/锁屏连播”全链路。
    private func sampleTracks() -> [Track] {
        let urls = [
            "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3",
            "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3",
            "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3"
        ]
        let names = ["示例曲目 1", "示例曲目 2", "示例曲目 3"]
        return urls.enumerated().map { i, u in
            Track(idx: i, title: names[i], album: "测试歌单", url: u, ext: "mp3", size: 0)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tracks = sampleTracks()
        engine.setTracks(tracks)

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

    /// 注入 window.App 桥接 shim，并把测试歌单塞进 window.__PLAYLIST__（player.html 启动时同步读取）。
    private func shimScript() -> String {
        var base = ""
        if let path = Bundle.main.path(forResource: "AppShim", ofType: "js"),
           let s = try? String(contentsOfFile: path, encoding: .utf8) {
            base = s
        }
        let playlist: [String: Any] = [
            "tracks": tracks.map { ["i": $0.idx, "n": $0.title, "a": $0.album, "e": $0.ext, "s": $0.size] },
            "albums": ["测试歌单"],
            "origin": "",
            "source": "builtin"
        ]
        var json = "{}"
        if let data = try? JSONSerialization.data(withJSONObject: playlist),
           let str = String(data: data, encoding: .utf8) { json = str }
        return base + "\nwindow.__PLAYLIST__ = \(json);\n"
    }

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
            if let idx = args.first as? Int {
                webView.evaluateJavaScript("window.onMeta && window.onMeta(\(idx), {})", completionHandler: nil)
            }
        case "login", "syncNow", "logout", "syncFrom":
            let js = "window.onSyncResult && window.onSyncResult({\"ok\":false,\"msg\":\"iOS 测试版暂不支持 NAS 登录同步\"})"
            webView.evaluateJavaScript(js, completionHandler: nil)
        default: break
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
            guard let data = try? JSONSerialization.data(withJSONObject: d),
                  let json = String(data: data, encoding: .utf8) else { return }
            self.webView.evaluateJavaScript(
                "window.onNativeState && window.onNativeState(\(json))", completionHandler: nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushState()
    }
}
