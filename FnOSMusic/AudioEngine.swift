import UIKit
import AVFoundation
import MediaPlayer

/// 一首曲目。url 可以是公开直链，也可以是 fnOS 签名直链（origin + uri 拼接）。
struct Track {
    let idx: Int
    let title: String
    let album: String
    let url: String
    let ext: String
    let size: Int
}

/// 断点续播快照：记录「上次在听哪首、听到哪、队列是什么」，用 UserDefaults 落盘。
/// 曲库重新同步后索引可能变化，所以额外存 title/album 做兜底匹配。
struct PlaybackSnapshot: Codable {
    var idx: Int            // 曲目索引
    var title: String       // 歌名（兜底匹配用）
    var album: String       // 专辑/目录（兜底匹配用）
    var positionMs: Int     // 播放位置
    var queueIdxs: [Int]    // 当时的播放队列
    var mode: Int           // 播放模式
    var savedAt: Double     // 记录时间（秒）
}

protocol AudioEngineDelegate: AnyObject {
    func engineStateChanged()
    func engineProgress(posMs: Int, durMs: Int, bufPct: Int)
    /// 播放失败时给用户的可见提示（toast），避免"点了没反应也没提示"
    func engineError(_ msg: String)
}

/// 原生播放引擎：
/// - AVPlayer 承载播放（锁屏/后台切换均由系统接管，不依赖 JS）
/// - MPNowPlayingInfoCenter + MPRemoteCommandCenter 提供锁屏控制条与耳机线控
/// - 播完自动下一曲（在原生层完成，规避 iOS 挂起 JS 线程导致连播失败的问题）
final class AudioEngine: NSObject {

    weak var delegate: AudioEngineDelegate?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var kvoItem: AVPlayerItem?
    private var timeObserved = false
    private var interruptionObserver: NSObjectProtocol?

    /// 是否有"要播放"的意图。用于两件事：
    /// 1) 音频项就绪时若播放器还停着，说明起播请求被吞了 → 补发一次
    /// 2) 看门狗据此判断"该出声却没出声"
    private var intentToPlay = false
    private var watchdog: DispatchWorkItem?
    private var stallRetries = 0
    private var bufferGraceUsed = false

    // MARK: - 断点续播状态

    private static let snapshotKey = "FnOSMusic.playbackSnapshot"
    /// 待执行的 seek（openCurrent 时消费一次）
    private var pendingSeekMs: Int = 0
    /// 本次恢复的目标位置：重建播放项重试后需要重新 seek，真正播放起来后清空
    private var resumeSeekMs: Int = 0
    /// 上次落盘时间，用于节流（进度回调每 0.5s 一次，不能每次都写盘）
    private var lastSnapshotAt: TimeInterval = 0

    /// 成功恢复到上次播放时回调（曲目, 位置毫秒），供 UI 给个提示
    var onResumed: ((Track, Int) -> Void)?

    var tracks: [Track] = []
    private var queue: [Track] = []
    private var qpos: Int = -1
    var mode: Int = 0          // 0 顺序 / 1 单曲循环 / 2 随机
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var durationMs: Int = 0
    private(set) var positionMs: Int = 0
    private(set) var errorMsg: String = ""

    override init() {
        super.init()
        let p = AVPlayer()
        // 远程直链（FN Connect 中继）下，"等缓冲足够再播"的启发式有时永远不满足，
        // 表现就是点了歌不出声、进度也不走秒。关掉它，改用 playImmediately 立即起播；
        // 真卡死交给看门狗重建播放项重试。
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        addTimeObserver()
        setupRemoteCommands()
        setupInterruptionObserver()
    }

    deinit {
        if let t = timeObserverToken { player?.removeTimeObserver(t) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        watchdog?.cancel()
        removeKVO()
    }

    // MARK: - 队列

    func setQueue(indices: [Int], startPos: Int) {
        let list = indices.compactMap { i -> Track? in
            (i >= 0 && i < tracks.count) ? tracks[i] : nil
        }
        queue = list.isEmpty ? tracks : list
        qpos = min(max(startPos, 0), max(queue.count - 1, 0))
        openCurrent(autoplay: true)
    }

    func playTrack(_ idx: Int) {
        guard idx >= 0, idx < tracks.count else { return }
        queue = tracks
        qpos = idx
        openCurrent(autoplay: true)
    }

    func toggle() {
        guard player != nil else { return }
        if isPlaying { pause() } else { play() }
    }

    func next(userTriggered: Bool = true) {
        guard !queue.isEmpty else { return }
        if mode == 2 {
            qpos = Int.random(in: 0..<queue.count)
        } else if mode == 1, !userTriggered {
            // 单曲循环：自然播完重头
        } else {
            qpos = (qpos + 1) % queue.count
        }
        openCurrent(autoplay: true)
    }

    func prev() {
        guard !queue.isEmpty else { return }
        if mode == 2 {
            qpos = Int.random(in: 0..<queue.count)
        } else {
            qpos = (qpos - 1 + queue.count) % queue.count
        }
        openCurrent(autoplay: true)
    }

    func seek(ms: Int) {
        guard let player = player else { return }
        let t = CMTime(seconds: Double(ms) / 1000.0, preferredTimescale: 1000)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setMode(_ m: Int) { mode = m; notifyState() }

    var currentTrack: Track? {
        guard qpos >= 0, qpos < queue.count else { return nil }
        return queue[qpos]
    }

    // MARK: - 断点续播（记录 / 恢复）

    /// 记录当前播放状态。默认节流 5 秒一次；
    /// force = true 用于「暂停 / 切歌 / 退到后台 / 退出」这些关键时机，立即落盘。
    func saveSnapshot(force: Bool = false) {
        guard let t = currentTrack else { return }
        let now = Date().timeIntervalSince1970
        if !force, now - lastSnapshotAt < 5 { return }
        lastSnapshotAt = now

        // 以播放器实际时间为准（比缓存的 positionMs 新）
        var pos = positionMs
        if let p = player {
            let s = CMTimeGetSeconds(p.currentTime())
            if s.isFinite { pos = Int(s * 1000) }
        }
        if pos < 0 { pos = 0 }
        // 已接近结尾：记为从头开始，避免下次打开瞬间触发「播完 → 自动下一曲」
        if durationMs > 0, pos > durationMs - 5000 { pos = 0 }

        let snap = PlaybackSnapshot(idx: t.idx, title: t.title, album: t.album,
                                    positionMs: pos,
                                    queueIdxs: queue.map { $0.idx },
                                    mode: mode, savedAt: now)
        if let d = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(d, forKey: Self.snapshotKey)
        }
    }

    /// 清掉断点记录（退出登录 / 曲库清空时调用，避免下次打开还去续播旧账号的歌）
    func clearSnapshot() {
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
        lastSnapshotAt = 0
    }

    /// 启动续播：读出上次记录，还原队列、曲目、位置并自动播放。返回是否恢复成功。
    @discardableResult
    func resumeLastSession() -> Bool {
        guard !tracks.isEmpty,
              let d = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snap = try? JSONDecoder().decode(PlaybackSnapshot.self, from: d) else { return false }

        // 先按索引找；曲库重新同步后索引可能变了，退化成「歌名 + 专辑」匹配
        var hit = tracks.first(where: { $0.idx == snap.idx })
        if hit == nil {
            hit = tracks.first(where: { $0.title == snap.title && $0.album == snap.album })
        }
        guard let target = hit else {
            // 曲库里找不到（可能这次曲库还没同步好）→ 保留记录，下次启动再试。
            // 只有明确退出登录时才由 clearSnapshot() 清除。
            return false
        }

        // 还原队列（已不在库中的曲目直接丢弃）
        var q: [Track] = snap.queueIdxs.compactMap { i in tracks.first(where: { $0.idx == i }) }
        if q.isEmpty { q = tracks }
        guard let pos = q.firstIndex(where: { $0.idx == target.idx }) else { return false }

        mode = snap.mode
        queue = q
        qpos = pos
        let seekTo = max(0, snap.positionMs)
        resumeSeekMs = seekTo
        pendingSeekMs = seekTo
        lastSnapshotAt = 0

        openCurrent(autoplay: true)
        onResumed?(target, seekTo)
        return true
    }

    /// 执行待恢复的 seek（在起播前调用；未就绪时 AVPlayer 会自行排队，就绪后再补一次更稳）
    private func applyPendingSeek() {
        guard pendingSeekMs > 0, let player = player else { return }
        let ms = pendingSeekMs
        pendingSeekMs = 0
        let target = CMTime(seconds: Double(ms) / 1000.0, preferredTimescale: 1000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - 播放

    private func openCurrent(autoplay: Bool, isRetry: Bool = false) {
        guard qpos >= 0, qpos < queue.count else { return }
        let t = queue[qpos]
        isLoading = true
        errorMsg = ""
        intentToPlay = autoplay
        // 切歌即重置进度缓存：否则这期间若落盘会把「上一首的位置」记到新曲上
        positionMs = 0
        durationMs = 0
        if !isRetry {
            stallRetries = 0
            bufferGraceUsed = false
        }
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        removeKVO()

        let playURL = resolveURL(t.url)

        // 给播放请求带 Cookie（fnos-token）与移动端 UA。若 fnOS 直链需要会话鉴权，
        // AVPlayer 默认不带 Cookie 就会 401/403 → 无声。这里显式注入。
        var hdrs: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
        ]
        let ck = Store.shared.cookie
        if !ck.isEmpty { hdrs["Cookie"] = ck }
        let asset = AVURLAsset(url: playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": hdrs])
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        player?.replaceCurrentItem(with: item)

        addTimeObserver()
        setupKVO()
        setupEndObserver(for: item)
        updateNowPlaying()

        // 断点续播：起播前先 seek 到上次的位置
        applyPendingSeek()

        notifyState()
        if autoplay {
            play()
            armWatchdog()
        }
        // 切歌即记录当前曲目：即便马上杀掉 App，下次也知道"上次在听哪首"。
        // 正在做断点恢复时不写（此刻 seek 还没完成，位置会被误写成 0，反而把断点抹掉）。
        if resumeSeekMs == 0 {
            saveSnapshot(force: true)
        }
    }

    /// 健壮地解析播放地址：
    /// - 先试 URL(string:)，含中文等非法字符会返回 nil
    /// - 失败则对全串做 percent-encode（保留已编码的 % 和合法保留字符）再试
    /// - 兜底空文件 URL（播放会失败，但不会崩）
    private func resolveURL(_ raw: String) -> URL {
        if let u = URL(string: raw), u.scheme != nil, u.host != nil {
            return u
        }
        // 中文/空格等非法字符导致 URL(string:) 返回 nil，做一次兜底编码
        if let enc = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let u = URL(string: enc), u.scheme != nil, u.host != nil {
            return u
        }
        return URL(fileURLWithPath: "")
    }

    func play() {
        guard let player = player else { return }
        intentToPlay = true
        // 每次起播都重新激活音频会话。只在 App 启动时激活一次是不够的：
        // 来电、其他 App 抢占、系统回收都会让会话失效，之后 play() 会"成功但没声音"。
        activateAudioSession()
        guard player.currentItem != nil else { return }
        // playImmediately 会无视"缓冲足够才播"的等待逻辑，直接起播
        player.playImmediately(atRate: 1.0)
        if player.rate == 0 { player.play() }   // 兜底：个别情况下 playImmediately 被忽略
        notifyState()
    }

    func pause() {
        intentToPlay = false
        watchdog?.cancel()
        player?.pause()
        isPlaying = false
        isLoading = false
        // 暂停是「用户停下来」的关键时机，立即记录位置
        saveSnapshot(force: true)
        updateNowPlayingPlaybackState()
        notifyState()
    }

    private func onEnded() {
        if mode == 1 {
            player?.seek(to: .zero)
            play()
            return
        }
        next(userTriggered: false)
    }

    // MARK: - 播放稳定性

    /// 激活音频会话。失败会让 AVPlayer「静默失败」——点了没声音也不走秒，所以每次起播都调用。
    @discardableResult
    private func activateAudioSession() -> Bool {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothHFP])
            try s.setActive(true)
            return true
        } catch {
            return false
        }
    }

    /// 来电 / 其他 App 抢占结束后，若本来是要播放的，自动把会话抢回来并续播
    private func setupInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self.isPlaying = false
                self.notifyState()
            } else if self.intentToPlay {
                self.play()
            }
        }
    }

    /// 起播看门狗：delay 秒后仍没出声也没走秒 → 重建播放项重试（最多 2 次），
    /// 避免出现"点了歌没声音、也没走秒、还不报错"这种卡死状态。
    private func armWatchdog(delay: Double = 6) {
        watchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.checkStall() }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func checkStall() {
        guard intentToPlay, let player = player else { return }
        if player.rate > 0 || player.timeControlStatus == .playing { return }   // 已正常播放
        if positionMs > 300 { return }                                          // 已在走秒

        let st = player.currentItem?.status

        // 已就绪、系统正在等缓冲：这是"真在缓冲"，给一轮宽限，不重建播放项
        if st == .readyToPlay,
           player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
           !bufferGraceUsed {
            bufferGraceUsed = true
            armWatchdog(delay: 10)
            return
        }

        if stallRetries >= 2 {
            errorMsg = "播放没起来，请再点一次或重新同步曲库"
            notifyState()
            delegate?.engineError(errorMsg)
            return
        }
        stallRetries += 1
        activateAudioSession()
        // 重建播放项会丢掉当前位置，续播场景要重新回到断点
        if resumeSeekMs > 0 { pendingSeekMs = resumeSeekMs }
        openCurrent(autoplay: true, isRetry: true)
    }

    // MARK: - 观察者

    private func addTimeObserver() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval,
                                                            queue: .main) { [weak self] _ in
            self?.tick()
        }
    }

    private func setupEndObserver(for item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.onEnded()
        }
    }

    private func setupKVO() {
        // 先干净地移除旧的，再按需注册新的，避免重复 add 或未注册就 remove
        removeKVO()
        if !timeObserved {
            player?.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
            timeObserved = true
        }
        if let item = playerItem {
            item.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
            kvoItem = item
        }
    }

    private func removeKVO() {
        // ⚠️ 未注册就 removeObserver 会抛 NSException（Swift 接不住，直接闪退），
        // 所以必须用标志位/记录判断，绝不能无条件 remove。
        if timeObserved {
            player?.removeObserver(self, forKeyPath: "timeControlStatus")
            timeObserved = false
        }
        if let old = kvoItem {
            old.removeObserver(self, forKeyPath: "status")
            kvoItem = nil
        }
    }

    private func tick() {
        guard let player = player else { return }
        let pos = CMTimeGetSeconds(player.currentTime())
        positionMs = pos.isFinite ? Int(pos * 1000) : 0
        if let dur = player.currentItem?.duration, dur.seconds.isFinite {
            durationMs = Int(dur.seconds * 1000)
        }
        delegate?.engineProgress(posMs: positionMs, durMs: durationMs, bufPct: 0)
        // 播放中每 5 秒落盘一次断点（内部节流，不会每次都写 UserDefaults）
        saveSnapshot()
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "timeControlStatus" {
            let st = player?.timeControlStatus ?? .paused
            switch st {
            case .playing:
                isPlaying = true; isLoading = false
                resumeSeekMs = 0        // 已正常播放，断点位置的兜底逻辑不再需要
            case .waitingToPlayAtSpecifiedRate:
                isLoading = true; isPlaying = false
            default:
                isPlaying = false; isLoading = false
            }
            updateNowPlayingPlaybackState()
            notifyState()
        } else if keyPath == "status" {
            if let item = playerItem, item.status == .failed {
                errorMsg = item.error?.localizedDescription ?? "播放失败"
                notifyState()
                delegate?.engineError("播放失败：\(errorMsg)")
            } else if let item = playerItem, item.status == .readyToPlay {
                isLoading = false
                // 断点续播：未就绪时发出的 seek 可能被忽略，这里补一次
                applyPendingSeek()
                // 上次是在末尾附近退出的 → 从头开始，避免一打开就「播完 → 跳下一曲」
                if resumeSeekMs > 0, let p = player, item.duration.seconds.isFinite,
                   item.duration.seconds > 0,
                   CMTimeGetSeconds(p.currentTime()) > item.duration.seconds - 5 {
                    resumeSeekMs = 0
                    pendingSeekMs = 0
                    p.seek(to: .zero)
                }
                // 起播请求可能早于"就绪"被系统吞掉 → 这里补发一次，这是"没声音也没走秒"的常见成因
                if intentToPlay, let p = player, p.rate == 0 {
                    activateAudioSession()
                    p.playImmediately(atRate: 1.0)
                }
                updateNowPlaying()
                notifyState()
            }
        }
    }

    // MARK: - 锁屏 / 远程控制

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        rc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in self?.next(userTriggered: true); return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
    }

    private func artwork() -> MPMediaItemArtwork {
        let size = CGSize(width: 200, height: 200)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(red: 0.43, green: 0.55, blue: 1.0, alpha: 1).cgColor,
                          UIColor(red: 0.63, green: 0.42, blue: 1.0, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            c.drawLinearGradient(grad, start: .zero,
                                 end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return MPMediaItemArtwork(boundsSize: size) { _ in img }
    }

    func updateNowPlaying() {
        var info: [String: Any] = [:]
        if let t = currentTrack {
            info[MPMediaItemPropertyTitle] = t.title
            info[MPMediaItemPropertyArtist] = "飞牛 NAS"
            info[MPMediaItemPropertyAlbumTitle] = t.album.isEmpty ? "音乐" : t.album
        }
        info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPMediaItemPropertyArtwork] = artwork()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(positionMs) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func notifyState() {
        delegate?.engineStateChanged()
    }
}
