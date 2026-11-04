#if os(iOS)
import SpellcrestProtocol
import UIKit

/// The iOS app around a game. UIKit makes one of these as the app's delegate, and another for its window's scene.
final class GameApp: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    static var resolution = Size(320, 180)
    /// The game, which `GameView` asks for its canvas for the display as it's laid out (`Game.resolution(for:)`).
    static var game: (any Game)?
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
            let code = key.keyCode.rawValue // a HID usage, as a GCKeyCode's (Input.keyMap)
            if down { Input.keys.insert(code) } else { Input.keys.remove(code) }
        }
    }
}

/// The touch controls, drawn over the game as `Input.touchLayout` lays them out: a D-pad or a stick, and its buttons.
/// Every finger that lands on the buttons or the D-pad holds the buttons under it, the first on the left half off them
/// is the stick's when there is one, and the first that's neither is the game's pointer. They hide while a keyboard or
/// controller is used (`GameView`), and come back with a touch; and they stand aside while the game says
/// (`Input.touchControlsAside`).
final class TouchControls: UIView {
    private var held: Set<Button> = []
    private var fingers: Set<UITouch> = [] // on the buttons or the D-pad
    private var thumb: UITouch? // the stick's, and where it landed
    private var base = CGPoint.zero
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
            if aside { (fingers, thumb, held, Input.touched, Input.touchStick) = ([], nil, [], [], .zero) }
            setNeedsDisplay()
            report()
        }
    }
    /// How the game lays them out (`Input.touchLayout`), which `GameView` passes on each frame.
    var layout = TouchLayout.standard {
        didSet {
            guard layout != oldValue else { return }
            (fingers, thumb, held, Input.touched, Input.touchStick) = ([], nil, [], [], .zero)
            setNeedsDisplay()
            report()
        }
    }
    private var showing: Bool { shown && !aside }
    private var images: [ImageName: (up: CGImage, held: CGImage?)?] = [:] // the buttons' own, as read

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isMultipleTouchEnabled = true
        contentMode = .redraw // the layout depends on the size
    }

    required init?(coder: NSCoder) { fatalError("TouchControls is created in code") }

    private var places: TouchPlaces {
        TouchPlaces(layout, size: bounds.size, left: safeAreaInsets.left, right: safeAreaInsets.right, bottom: safeAreaInsets.bottom,
                    top: safeAreaInsets.top)
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
    private var viewport: Viewport { fit(Input.canvas, in: bounds.size, top: safeAreaInsets.top) }

    /// Tells the game where the controls are over its canvas, `Input.touchControls`, as they show or move.
    private func report() {
        let (canvas, viewport) = (Input.canvas, viewport)
        Input.touchControls = showing ? places.rectangles(over: canvas, at: CGPoint(x: viewport.originX, y: viewport.originY),
                                                         scale: viewport.width / Double(canvas.width)) : []
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let places = places
        for touch in touches {
            let point = touch.location(in: self)
            switch showing ? places.claim(point) : nil {
            case .buttons: fingers.insert(touch)
            case .stick where thumb == nil: (thumb, base) = (touch, point)
            default: if pointing == nil { pointing = touch }
            }
        }
        shown = true
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { update() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        fingers.subtract(touches)
        if let thumb, touches.contains(thumb) { self.thumb = nil }
        if let pointing, touches.contains(pointing) { self.pointing = nil }
        update()
    }

    private func update() {
        let (canvas, viewport) = (Input.canvas, viewport)
        Input.point(pointing.map { pixel(at: $0.location(in: self), in: viewport, canvas: canvas) }, down: pointing != nil)
        let places = places
        let stick = thumb.map { places.pushed(from: base, to: $0.location(in: self)) } ?? .zero
        let now = fingers.reduce(into: Input.buttons(pushedTo: stick)) { $0.formUnion(places.buttons(at: $1.location(in: self))) }
        if stick != Input.touchStick || thumb != nil { setNeedsDisplay() } // the knob follows the thumb
        Input.touchStick = stick
        guard now != held else { return }
        held = now
        Input.touched = now
        setNeedsDisplay()
    }

    /// A button's own image, its first frame and, if it has one, its second, by its sheet: read once.
    private func frames(_ image: ImageName) -> (up: CGImage, held: CGImage?)? {
        if let read = images[image] { return read }
        var read: (up: CGImage, held: CGImage?)?
        if let url = Assets.url(image.name + ".png"), let whole = UIImage(contentsOfFile: url.path)?.cgImage {
            let sheet = Assets.url(image.name + ".json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(SheetFile.self, from: $0) }
            let (width, height) = (sheet?.frameWidth ?? whole.width, sheet?.frameHeight ?? whole.height)
            let up = whole.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)) ?? whole
            let second = whole.width >= width * 2 ? whole.cropping(to: CGRect(x: width, y: 0, width: width, height: height)) : nil
            read = (up, second)
        }
        images[image] = read
        return read
    }

    override func draw(_ rect: CGRect) {
        guard showing, let context = UIGraphicsGetCurrentContext() else { return }
        let places = places
        func circle(_ center: CGPoint, _ radius: Double, alpha: Double) {
            UIColor(white: 1, alpha: alpha).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
        if places.stick { // at home until a thumb lands, then where it landed, the knob under the thumb
            let landed = thumb != nil
            let middle = landed ? base : places.home, push = landed ? Input.touchStick * places.reach : .zero
            circle(middle, places.reach, alpha: landed ? 0.18 : 0.1)
            circle(CGPoint(x: middle.x + push.x, y: middle.y + push.y), places.reach * 0.45, alpha: landed ? 0.5 : 0.2)
        } else {
            circle(places.home, TouchPlaces.pad, alpha: 0.25)
            for (button, dx, dy) in [(Button.left, -1.0, 0.0), (.right, 1, 0), (.up, 0, -1), (.down, 0, 1)] {
                let center = CGPoint(x: places.home.x + dx * TouchPlaces.pad * 0.6, y: places.home.y + dy * TouchPlaces.pad * 0.6)
                circle(center, TouchPlaces.pad * 0.32, alpha: held.contains(button) ? 0.55 : 0.25)
            }
        }
        context.interpolationQuality = .none // the game's art, its pixels square
        for place in layout.buttons {
            let center = places.middle(of: place), pressed = held.contains(place.button)
            if let image = place.image, let drawn = frames(image) {
                let picture = pressed ? drawn.held ?? drawn.up : drawn.up
                let scale = max(1, (place.radius * 2 / Double(max(picture.width, picture.height))).rounded(.down)) // whole numbers
                let (width, height) = (Double(picture.width) * scale, Double(picture.height) * scale)
                UIImage(cgImage: picture).draw(in: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                                               blendMode: .normal, alpha: pressed && drawn.held == nil ? 0.6 : 1)
                continue
            }
            circle(center, place.radius, alpha: pressed ? 0.55 : 0.25)
            UIColor(white: 1, alpha: 0.75).set()
            if place.button == .start { // three bars
                for k in -1...1 { UIRectFill(CGRect(x: center.x - place.radius * 0.4, y: center.y + Double(k) * place.radius * 0.28 - 1.5, width: place.radius * 0.8, height: 3)) }
                continue
            }
            let name = switch place.button {
            case .a: "A"
            case .b: "B"
            case .x: "X"
            case .y: "Y"
            default: "\(place.button)"
            }
            let label = NSAttributedString(string: name, attributes: [.font: UIFont.boldSystemFont(ofSize: 18 * place.radius / 26),
                                                                      .foregroundColor: UIColor(white: 1, alpha: 0.75)])
            label.draw(at: CGPoint(x: center.x - label.size().width / 2, y: center.y - label.size().height / 2))
        }
    }
}
#endif
