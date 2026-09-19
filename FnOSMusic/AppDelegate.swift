import UIKit
import AVFoundation

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 配置后台音频会话：这是锁屏连播能工作的关键（原生层，不依赖 JS）
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default,
                              options: [.allowAirPlay, .allowBluetoothHFP])
            try s.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()

        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = ViewController.pageBg
        w.rootViewController = ViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}
