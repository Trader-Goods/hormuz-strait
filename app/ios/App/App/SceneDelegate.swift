import UIKit
import Capacitor

class HormuzViewController: CAPBridgeViewController {
    private let navy = UIColor(red: 7.0 / 255.0, green: 26.0 / 255.0, blue: 43.0 / 255.0, alpha: 1)

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        view.backgroundColor = navy
        guard let webView else { return }
        let scroll = webView.scrollView
        scroll.bounces = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.isScrollEnabled = false
        scroll.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = true
        webView.backgroundColor = navy
        scroll.backgroundColor = navy
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        GameAudioSession.apply()
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    override var prefersStatusBarHidden: Bool { true }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let controller = HormuzViewController()
        window = UIWindow(windowScene: windowScene)
        window?.rootViewController = controller
        window?.backgroundColor = UIColor(red: 7.0 / 255.0, green: 26.0 / 255.0, blue: 43.0 / 255.0, alpha: 1)
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        GameAudioSession.apply()
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
