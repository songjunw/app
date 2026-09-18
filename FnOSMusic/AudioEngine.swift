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
    let lrc: String   // 同名 .lrc 的签名直链（没有则为空串）
}

protocol AudioEngineDelegate: AnyObject {
    func engineStateChanged()
    func engineProgress(posMs: Int, durMs: Int, bufPct: Int)
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

    var tracks: [Track] = []
    private var queue: [Track] = []
    private var qpos: Int = -1
    var mode: Int = 0          // 0 顺序 / 1 单曲循环 / 2 随机
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var durationMs: Int = 0
    private(set) var positionMs: Int = 0
    private(set) var errorMsg: String = ""
    private var volume: Float = 1.0

    override init() {
        super.init()
        player = AVPlayer()
        player?.volume = volume
        addTimeObserver()
        setupRemoteCommands()
    }

    deinit {
        if let t = timeObserverToken { player?.removeTimeObserver(t) }
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
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

    func setVolume(_ v: Float) {
        volume = max(0, min(1, v))
        player?.volume = volume
    }

    var currentTrack: Track? {
        guard qpos >= 0, qpos < queue.count else { return nil }
        return queue[qpos]
    }

    // MARK: - 播放

    private func openCurrent(autoplay: Bool) {
        guard qpos >= 0, qpos < queue.count else { return }
        let t = queue[qpos]
        isLoading = true
        errorMsg = ""
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        removeKVO()

        let playURL = resolveURL(t.url)
        SyncLog.step("AudioEngine.openCurrent idx=\(t.idx) title=\(t.title)")
        SyncLog.step("AudioEngine.openCurrent url=\(playURL.absoluteString)")
        let asset = AVURLAsset(url: playURL)
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        player?.replaceCurrentItem(with: item)

        addTimeObserver()
        setupKVO()
        setupEndObserver(for: item)
        updateNowPlaying()
        notifyState()
        if autoplay { play() }
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
        SyncLog.step("AudioEngine.resolveURL FAIL: \(raw)")
        return URL(fileURLWithPath: "")
    }

    func play() {
        guard let player = player else { return }
        player.play()
        notifyState()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        isLoading = false
        updateNowPlayingPlaybackState()
        notifyState()
    }

    private func onEnded() {
        if mode == 1 {
            player?.seek(to: .zero)
            player?.play()
            return
        }
        next(userTriggered: false)
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
                let code = (item.error as NSError?)?.code ?? 0
                SyncLog.step("AudioEngine.item FAILED code=\(code) err=\(errorMsg)")
                notifyState()
            } else if let item = playerItem, item.status == .readyToPlay {
                isLoading = false
                SyncLog.step("AudioEngine.item readyToPlay")
            } else if let item = playerItem, item.status == .unknown {
                SyncLog.step("AudioEngine.item status=unknown")
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
