#if os(iOS)
import GameController
import UIKit
#endif
import CoreGraphics

/// Where the touch controls go in a view of `size` points: a D-pad at the bottom left, and A, B, X and Y at the bottom
/// right in a diamond, as on a Super Nintendo's pad (A right, B below, X above, Y left), clear of the safe area's
/// `left`, `right` and `bottom` insets (rounded corners, the notch).
struct TouchLayout {
    static let pad = 50.0, button = 26.0 // radii, in points
    static let spread = button * 1.6 // from the diamond's middle to each button's
    let dpad, middle, a, b, x, y: CGPoint

    init(size: CGSize, left: Double, right: Double, bottom: Double) {
        let floor = size.height - max(bottom, 12) - 16
        dpad = CGPoint(x: left + 24 + Self.pad, y: floor - Self.pad)
        middle = CGPoint(x: size.width - right - 24 - Self.button - Self.spread, y: floor - Self.button - Self.spread)
        a = CGPoint(x: middle.x + Self.spread, y: middle.y)
        b = CGPoint(x: middle.x, y: middle.y + Self.spread)
        x = CGPoint(x: middle.x, y: middle.y - Self.spread)
        y = CGPoint(x: middle.x - Self.spread, y: middle.y)
    }

    /// The buttons a finger at `point` holds. Between two of the D-pad's directions, it holds both.
    func buttons(at point: CGPoint) -> Set<Button> {
        var held: Set<Button> = []
        let (dx, dy) = (point.x - dpad.x, point.y - dpad.y)
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > Self.pad * 0.2, distance < Self.pad * 1.6 { // some slack all round: fingers are big
            if abs(dx) > distance * 0.38 { held.insert(dx < 0 ? .left : .right) } // 0.38 ≈ sin 22.5°: eight directions
            if abs(dy) > distance * 0.38 { held.insert(dy < 0 ? .up : .down) }
        }
        for (center, button) in [(a, Button.a), (b, .b), (x, .x), (y, .y)] where hypot(point.x - center.x, point.y - center.y) < Self.button * 1.4 {
            held.insert(button) // between two, both: one thumb can press two
        }
        return held
    }

    /// Whether a finger landing at `point` is the controls': on the D-pad, middle and all, or among the buttons, with the
    /// slack `buttons(at:)` gives them. The others are the game's pointer.
    func covers(_ point: CGPoint) -> Bool {
        hypot(point.x - dpad.x, point.y - dpad.y) < Self.pad * 1.6 || hypot(point.x - middle.x, point.y - middle.y) < Self.spread + Self.button * 1.4
    }

    /// Where the D-pad and the buttons are drawn, in the pixels of a `canvas` shown with its top-left corner at `origin`,
    /// `scale` points to a pixel: those parts of them over it, for `Input.touchControls`.
    func rectangles(over canvas: Size, at origin: CGPoint, scale: Double) -> [Rect] {
        let reach = Self.spread + Self.button
        let drawn = [CGRect(x: dpad.x - Self.pad, y: dpad.y - Self.pad, width: Self.pad * 2, height: Self.pad * 2),
                     CGRect(x: middle.x - reach, y: middle.y - reach, width: reach * 2, height: reach * 2)]
        return drawn.compactMap { box in
            let pixels = CGRect(x: (box.minX - origin.x) / scale, y: (box.minY - origin.y) / scale, width: box.width / scale, height: box.height / scale)
                .intersection(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            guard !pixels.isEmpty else { return nil }
            let (left, top) = (Int(pixels.minX.rounded(.down)), Int(pixels.minY.rounded(.down)))
            return Rect(x: left, y: top, width: Int(pixels.maxX.rounded(.up)) - left, height: Int(pixels.maxY.rounded(.up)) - top)
        }
    }
}

#if os(iOS)
/// The iOS app around a game. UIKit makes one of these as the app's delegate, and another for its window's scene.
final class GameApp: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    static var resolution = Size(320, 180)
    var window: UIWindow?

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = GameApp.self
        return configuration
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        window = UIWindow(windowScene: scene)
        window?.rootViewController = GameViewController()
        window?.makeKeyAndVisible()
    }
}

/// The game scaled up to the screen's edges, with the touch controls over it, or below it when the screen is portrait.
final class GameViewController: UIViewController {
    override func loadView() {
        let game = GameView(resolution: GameApp.resolution)
        let controls = TouchControls(frame: game.bounds)
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        game.addSubview(controls)
        view = game
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // A keyboard's keys, as UIKit has them: GCKeyboard misses the ones the editor's preview sends a simulator.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { press(presses, down: true) }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { press(presses, down: false) }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { press(presses, down: false) }

    private func press(_ presses: Set<UIPress>, down: Bool) {
        for case let key? in presses.map(\.key) {
            let code = GCKeyCode(rawValue: key.keyCode.rawValue)
            if down { Input.keys.insert(code) } else { Input.keys.remove(code) }
        }
    }
}

/// A D-pad and A, B, X and Y buttons, drawn over the game. Every finger that lands on them holds the buttons under it,
/// and the first that doesn't is the game's pointer. They hide while a keyboard or controller is used (`GameView`),
/// and come back with a touch; and they stand aside while the game says (`Input.touchControlsAside`).
final class TouchControls: UIView {
    private var held: Set<Button> = []
    private var fingers: Set<UITouch> = [] // on the controls
    private var pointing: UITouch? // the pointer
    var shown = true {
        didSet {
            guard shown != oldValue else { return }
            setNeedsDisplay()
            report()
        }
    }
    /// Standing aside for the game (`Input.touchControlsAside`): what's held let go, and every finger the pointer.
    var aside = false {
        didSet {
            guard aside != oldValue else { return }
            if aside { (fingers, held, Input.touched) = ([], [], []) }
            setNeedsDisplay()
            report()
        }
    }
    private var showing: Bool { shown && !aside }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isMultipleTouchEnabled = true
        contentMode = .redraw // the layout depends on the size
    }

    required init?(coder: NSCoder) { fatalError("TouchControls is created in code") }

    private var layout: TouchLayout {
        TouchLayout(size: bounds.size, left: safeAreaInsets.left, right: safeAreaInsets.right, bottom: safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        setNeedsDisplay()
        report()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }

    /// Where the canvas is in the view, as the game's view draws it (`fit`), below the safe area's top when upright.
    private var viewport: MTLViewport { fit(GameApp.resolution, in: bounds.size, top: safeAreaInsets.top) }

    /// Tells the game where the controls are over its canvas, `Input.touchControls`, as they show or move.
    private func report() {
        let (canvas, viewport) = (GameApp.resolution, viewport)
        Input.touchControls = showing ? layout.rectangles(over: canvas, at: CGPoint(x: viewport.originX, y: viewport.originY),
                                                         scale: viewport.width / Double(canvas.width)) : []
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let layout = layout
        for touch in touches {
            if showing, layout.covers(touch.location(in: self)) { fingers.insert(touch) } else if pointing == nil { pointing = touch }
        }
        shown = true
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        fingers.subtract(touches)
        if let pointing, touches.contains(pointing) { self.pointing = nil }
        update()
    }

    private func update() {
        let (canvas, viewport) = (GameApp.resolution, viewport)
        Input.point(pointing.map { pixel(at: $0.location(in: self), in: viewport, canvas: canvas) }, down: pointing != nil)
        let layout = layout
        let now = fingers.reduce(into: Set<Button>()) { $0.formUnion(layout.buttons(at: $1.location(in: self))) }
        guard now != held else { return }
        held = now
        Input.touched = now
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard showing else { return }
        let layout = layout
        func circle(_ center: CGPoint, _ radius: Double, pressed: Bool) {
            UIColor(white: 1, alpha: pressed ? 0.55 : 0.25).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        circle(layout.dpad, TouchLayout.pad, pressed: false)
        for (button, dx, dy) in [(Button.left, -1.0, 0.0), (.right, 1, 0), (.up, 0, -1), (.down, 0, 1)] {
            let center = CGPoint(x: layout.dpad.x + dx * TouchLayout.pad * 0.6, y: layout.dpad.y + dy * TouchLayout.pad * 0.6)
            circle(center, TouchLayout.pad * 0.32, pressed: held.contains(button))
        }
        for (button, center, name) in [(Button.a, layout.a, "A"), (.b, layout.b, "B"), (.x, layout.x, "X"), (.y, layout.y, "Y")] {
            circle(center, TouchLayout.button, pressed: held.contains(button))
            let label = NSAttributedString(string: name, attributes: [.font: UIFont.boldSystemFont(ofSize: 18),
                                                                      .foregroundColor: UIColor(white: 1, alpha: 0.75)])
            label.draw(at: CGPoint(x: center.x - label.size().width / 2, y: center.y - label.size().height / 2))
        }
    }
}
#endif
