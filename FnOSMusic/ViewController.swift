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

        // 页面底色（与 player.html 的 --bg 一致）。window / view / webView 统一用这个颜色，
        // 万一还有缝隙也不会露出纯黑或纯白，视觉上始终是连续的深色。
        view.backgroundColor = Self.pageBg

        webView = WKWebView(frame: view.bounds, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // 真正全屏：WebView 铺满整个屏幕（含刘海/底部 Home 指示条区域），
        // 安全区交给 HTML 的 env(safe-area-inset-*) 处理。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        webView.scrollView.bounces = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(webView)
        // 用约束钉在 view 的四条边（注意是 view 不是 safeAreaLayoutGuide）——这是铺满全屏的关键。
        // 若参照 safeAreaLayoutGuide，WebView 会被缩到安全区内，外面就露出黑边。
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        engine.delegate = self

        if let url = Bundle.main.url(forResource: "player", withExtension: "html") {
            // 必须用文件 URL 加载：loadHTMLString 会让 viewport-fit=cover 失效、
            // env(safe-area-inset-*) 恒为 0，导致页面缩在中间上下留黑。
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    /// 页面底色，与 player.html 的 --bg (#0b0d12) 保持一致
    static let pageBg = UIColor(red: 11/255.0, green: 13/255.0, blue: 18/255.0, alpha: 1)

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 等一帧，确保拿到最终布局再打点
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.logLayout()
        }
    }

    // MARK: - 布局诊断（测试期用，项目完成后移除）

    /// 把屏幕/窗口/WebView 的实际尺寸与安全区推给页面的运行日志面板。
    ///
    /// 为什么需要：App 若缺少 UILaunchScreen，iOS 会按"兼容模式"渲染（按宽度放大、上下补黑边），
    /// 此时 `UIScreen.bounds` 会比机型真实逻辑尺寸小。用 `bounds × scale` 和 `nativeBounds`
    /// 对比即可一眼判定是否铺满；nativeBounds 无论兼容与否都返回真实物理像素。
    private func logLayout() {
        let s = UIScreen.main
        let w = s.bounds.width * s.scale
        let h = s.bounds.height * s.scale
        let full = abs(w - s.nativeBounds.width) < 1 && abs(h - s.nativeBounds.height) < 1
        let msg = "[布局] " + (full ? "已铺满✅" : "未铺满❌(疑似兼容/letterbox模式)")
            + " screen=\(Int(s.bounds.width))x\(Int(s.bounds.height))"
            + " native=\(Int(s.nativeBounds.width))x\(Int(s.nativeBounds.height))"
            + " scale=\(Int(s.scale))"
            + " rendered=\(Int(w))x\(Int(h))"
            + " view=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
            + " web=\(Int(webView.frame.width))x\(Int(webView.frame.height))"
            + " safeTop=\(Int(view.safeAreaInsets.top)) safeBottom=\(Int(view.safeAreaInsets.bottom))"
        SyncLog.step(msg)
        engineLog(msg)
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
            "\nwindow.__STAT__ = \(statJSON());" +
            "\nwindow.__SYNCTRACE__ = \(traceJSON());\n"
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
        return jsonString(["saved": saved, "origin": cr.origin, "user": cr.user,
                           "root": cr.root, "lastSync": lastSyncMs()])
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

    /// 上次同步时间（毫秒时间戳，JS 的 fmtAgo 吃 ms）；解析失败返回 0 => 显示"从未"
    private func lastSyncMs() -> Double {
        let iso = Store.shared.syncedAt
        guard !iso.isEmpty else { return 0 }
        // 与 SyncManager.isoNow() 的输出格式严格一致（yyyy-MM-dd'T'HH:mm:ss.SSS'Z'，UTC）
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        if let d = f.date(from: iso) { return d.timeIntervalSince1970 * 1000 }
        return 0
    }

    /// 上次同步的落盘日志 + 是否异常中断（崩溃后重开可看到停在第几步）
    private func traceJSON() -> String {
        return jsonString(["crashed": SyncLog.crashed, "trace": SyncLog.trace])
    }

    private func jsonString(_ obj: Any) -> String {
        // ⚠️ JSONSerialization 要求顶层必须是 array/dictionary，否则抛的是
        // NSException（try? 接不住，直接闪退），所以必须先校验再调用。
        if let arr = obj as? [Any], let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) { return s }
        if let dic = obj as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: dic),
           let s = String(data: data, encoding: .utf8) { return s }
        return "{}"
    }
    /// String -> JS 字符串字面量（带双引号）。
    /// 绝不能用 JSONSerialization 直接编 String（顶层非容器会抛 NSException 且 try? 接不住），
    /// 改走 JSONEncoder（纯 Swift 错误路径）编码单元素数组后剥壳，转义/Unicode 全部正确。
    private func jsStr(_ s: String) -> String {
        if let data = try? JSONEncoder().encode([s]),
           let str = String(data: data, encoding: .utf8),
           str.hasPrefix("[\""), str.hasSuffix("\"]"), str.count >= 3 {
            return String(str.dropFirst().dropLast())
        }
        return "\"\""
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
            if let idx = args.first as? Int { requestMeta(idx: idx) }
        case "login":
            // args 下标先做边界检查，避免 JS 侧少传参数时数组越界闪退
            guard args.count >= 4,
                  let o = args[0] as? String, let u = args[1] as? String,
                  let p = args[2] as? String, let r = args[3] as? String else { return }
            let cr = Creds(origin: o, user: u, pass: p, root: r)
            cr.save()
            runSync()
        case "syncNow":
            runSync()
        case "logout":
            doLogout()
        case "toggleFavorite":
            guard args.count >= 1, let idx = args[0] as? Int else { return }
            if args.count >= 2, let on = args[1] as? Bool {
                Store.shared.setFav(idx, on)
            } else {
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
                 "window.__STAT__ = \(statJSON());" +
                 "window.__SYNCTRACE__ = \(traceJSON());"
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

    /// 播放引擎的运行日志 → 实时推给 JS 的 onNativeLog（测试期可见，项目完成后再移除）
    func engineLog(_ line: String) {
        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(
                "window.onNativeLog && window.onNativeLog(\(self.jsStr(line)))",
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
