import Combine
import UIKit
import RGPCore

/// Gives an external display (HDMI adapter, capture card) its own scene instead of a mirror of
/// the phone. That scene contains the clean gameplay layer and the scene cards, and nothing else:
/// no controls, no status, no account or pairing screens can appear on it.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        // Recorded so a test can tell whether iOS offered this app the external display at all.
        if connectingSceneSession.role != .windowApplication {
            ConnectionLog.shared.add("iOS offered a display of kind \(connectingSceneSession.role.rawValue); Creator Mode is \(CreatorHub.isEnabled ? "on" : "off").")
        }
        // A TV or monitor always gets the clean game picture, with or without Creator Mode:
        // bigger-screen play is useful to everyone, and a copy of the phone would put the app's
        // controls and status on the TV.
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplayDelegate.self
        }
        return configuration
    }
}

final class ExternalDisplayDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        // Fill the whole display: no shrinking for old TVs' edges, and the window sized to the
        // display rather than left at a default.
        scene.screen.overscanCompensation = .none
        let controller = UIViewController()
        let output = PublicOutputView()
        output.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view = output
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        let size = scene.coordinateSpace.bounds.size, native = scene.screen.nativeBounds.size
        ConnectionLog.shared.add("External display is \(Int(native.width))×\(Int(native.height)); output area \(Int(size.width))×\(Int(size.height)).")
        CreatorHub.shared.setExternalDisplay(connected: true)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        CreatorHub.shared.setExternalDisplay(connected: false)
    }
}

/// What the external display shows: the game picture, or a card when the audience scene is
/// not gameplay. Also used for the in-app audience preview.
final class PublicOutputView: UIView {
    private let card = UIImageView()
    private var observer: AnyCancellable?
    private let usesSharedLayer: Bool

    init(usesSharedLayer: Bool = true) {
        self.usesSharedLayer = usesSharedLayer
        super.init(frame: .zero)
        backgroundColor = .black
        if usesSharedLayer { layer.addSublayer(CreatorHub.shared.publicLayer) }
        card.contentMode = .scaleAspectFit
        card.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
        addSubview(card)
        observer = CreatorHub.shared.$effectiveScene.combineLatest(CreatorHub.shared.$sessionActive).receive(on: DispatchQueue.main).sink { [weak self] scene, _ in self?.show(scene) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func show(_ scene: PublicScene) {
        card.isHidden = scene == .gameplay
        guard scene != .gameplay else { return }
        // Nothing being played: say so plainly instead of "Reconnecting".
        let idle = scene == .reconnecting && !CreatorHub.shared.sessionActive
        card.image = SceneCard.image(scene, size: CGSize(width: 1280, height: 720), title: idle ? "Start a game on your phone" : nil)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if usesSharedLayer { CreatorHub.shared.publicLayer.frame = bounds }
        CATransaction.commit()
        card.frame = bounds
    }
}
