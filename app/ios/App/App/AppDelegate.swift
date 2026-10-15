import AVFoundation
import UIKit
import Capacitor

/// Web Audio in WKWebView often switches the session to `.playback`, which
/// ignores the hardware mute switch. `.soloAmbient` keeps game audio working
/// and silent when the mute switch is on.
enum GameAudioSession {
    private static var observing = false

    static func install() {
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if raw == AVAudioSession.RouteChangeReason.categoryChange.rawValue {
                    apply()
                }
            }
        }
        apply()
    }

    static func apply() {
        let session = AVAudioSession.sharedInstance()
        if session.category != .soloAmbient {
            try? session.setCategory(.soloAmbient, mode: .default)
        }
        try? session.setActive(true)
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        GameAudioSession.install()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        GameAudioSession.apply()
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}
