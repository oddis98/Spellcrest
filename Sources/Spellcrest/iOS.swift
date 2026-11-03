#if os(iOS)
import GameController
import UIKit
#endif
import CoreGraphics
import SpellcrestProtocol

/// How a game's touch controls are laid out on an iPhone or iPad (`Input.touchLayout`): how the player moves, on a
/// D-pad or a stick, and the buttons, each where the game puts it and as big as it says, in its own art if it gives
/// some. `standard`, the default, is a D-pad at the bottom left and A, B, X and Y in a diamond at the bottom right, as
/// on a Super Nintendo's pad. Games held sideways for two thumbs, as action games are, reach for a stick and an A the
/// biggest: `Input.touchLayout = TouchLayout(movement: .stick(), buttons: [.init(.a, at: [40, 44], radius: 34), …])`.
public struct TouchLayout: Sendable, Equatable {
    /// How the player moves on the touch controls.
    public enum Movement: Sendable, Equatable {
        /// A D-pad at the bottom left, eight ways, holding the buttons by where the thumb is on it.
        case dpad
        /// A stick that appears under the thumb wherever it lands on the left half, away from the buttons:
        /// `Input.direction` is the way from there to the thumb, from nothing at its dead zone to 1 at `reach` points
        /// and past it, as a controller's stick is, and the D-pad's buttons are held by its quarter once it's pushed
        /// half way, for games that read those. Until a thumb lands, a faint one shows at the bottom left.
        case stick(reach: Double = 44)
    }

    /// A corner of the room the screen leaves the controls, clear of its rounded corners, island and camera, that a
    /// button's place is measured from.
    public enum Corner: Sendable, Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    /// One of the buttons: which it is, where its middle is from a `corner`, in points in toward the screen's middle,
    /// and its radius in points, a finger's room on it a little more. Its `image`, if the game gives one, draws it: the
    /// image's first frame as it is, its second, if it has one, while it's held, each scaled by a whole number to the
    /// button's size. Without one, it's a circle with its letter, or for Start three bars.
    public struct Place: Sendable, Equatable {
        public var button: Button
        public var corner: Corner
        public var middle: Vector
        public var radius: Double
        public var image: ImageName?

        /// `button`, its middle `at` so many points in from `corner`, `radius` points round.
        public init(_ button: Button, from corner: Corner = .bottomRight, at middle: Vector, radius: Double = 26, image: ImageName? = nil) {
            (self.button, self.corner, self.middle, self.radius, self.image) = (button, corner, middle, radius, image)
        }
    }

    public var movement: Movement
    public var buttons: [Place]

    /// A layout of `movement` and `buttons`: by default, the D-pad and the diamond.
    public init(movement: Movement = .dpad, buttons: [Place] = TouchLayout.diamond) { (self.movement, self.buttons) = (movement, buttons) }

    /// A, B, X and Y in a diamond at the bottom right, A to the right, B below, X above and Y to the left, each 26
    /// points round, as every game had them before it could lay its own out.
    public static let diamond: [Place] = [Place(.a, at: [26, 67.6]), Place(.b, at: [67.6, 26]), Place(.x, at: [67.6, 109.2]),
                                          Place(.y, at: [109.2, 67.6])]

    /// The D-pad and the diamond.
    public static let standard = TouchLayout()
}

/// Where a `TouchLayout`'s controls are in a view of `size` points, clear of its safe area's `left`, `right`, `top` and
/// `bottom` insets: the D-pad or the stick's home at the bottom left, and each button from its corner.
struct TouchPlaces {
    static let pad = 50.0 // the D-pad's radius, in points
    let layout: TouchLayout
    let size: CGSize
    /// The room the controls are measured in: 24 points in from the sides, 16 up from the bottom (and the bottom's inset, or
    /// 12), and 16 down from the top's.
    let room: CGRect
    /// The D-pad's middle, or where the stick's at home.
    let home: CGPoint

    init(_ layout: TouchLayout = .standard, size: CGSize, left: Double, right: Double, bottom: Double, top: Double = 0) {
        (self.layout, self.size) = (layout, size)
        let floor = size.height - max(bottom, 12) - 16
        room = CGRect(x: left + 24, y: top + 16, width: size.width - right - 24 - (left + 24), height: floor - (top + 16))
        let reach: Double = if case .stick(let reach) = layout.movement { reach } else { Self.pad }
        home = CGPoint(x: room.minX + reach, y: room.maxY - reach)
    }

    /// The D-pad's radius, or the stick's reach.
    var reach: Double {
        if case .stick(let reach) = layout.movement { return reach }
        return Self.pad
    }

    var stick: Bool { layout.movement != .dpad }

    /// Where a button's middle is.
    func middle(of place: TouchLayout.Place) -> CGPoint {
        let x = place.corner == .topLeft || place.corner == .bottomLeft ? room.minX + place.middle.x : room.maxX - place.middle.x
        let y = place.corner == .topLeft || place.corner == .topRight ? room.minY + place.middle.y : room.maxY - place.middle.y
        return CGPoint(x: x, y: y)
    }

    /// The buttons from each corner, round the middle of them, as far out as their farthest's reach with a finger's slack:
    /// the diamond's middle is the controls' as the D-pad's is, so a thumb between buttons holds none rather than
    /// pointing at the game.
    var groups: [(middle: CGPoint, reach: Double)] {
        [TouchLayout.Corner.topLeft, .topRight, .bottomLeft, .bottomRight].compactMap { corner in
            let places = layout.buttons.filter { $0.corner == corner }
            guard !places.isEmpty else { return nil }
            let points = places.map(middle(of:))
            let middle = CGPoint(x: points.map(\.x).reduce(0, +) / Double(points.count), y: points.map(\.y).reduce(0, +) / Double(points.count))
            return (middle, zip(places, points).map { hypot($1.x - middle.x, $1.y - middle.y) + $0.radius * 1.4 }.max() ?? 0)
        }
    }

    /// The buttons a finger at `point` holds: those within a little more than their radius, two between two, and on the
    /// D-pad, by where it is, both of two directions between them.
    func buttons(at point: CGPoint) -> Set<Button> {
        var held: Set<Button> = []
        if !stick {
            let (dx, dy) = (point.x - home.x, point.y - home.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance > Self.pad * 0.2, distance < Self.pad * 1.6 { // some slack all round: fingers are big
                if abs(dx) > distance * 0.38 { held.insert(dx < 0 ? .left : .right) } // 0.38 ≈ sin 22.5°: eight directions
                if abs(dy) > distance * 0.38 { held.insert(dy < 0 ? .up : .down) }
            }
        }
        for place in layout.buttons {
            let middle = middle(of: place)
            if hypot(point.x - middle.x, point.y - middle.y) < place.radius * 1.4 { held.insert(place.button) } // one thumb can press two
        }
        return held
    }

    /// What a finger landing at `point` is: on the buttons, or the D-pad; the stick, on the left half off the buttons;
    /// or nil, the game's pointer.
    enum Claim { case buttons, stick }
    func claim(_ point: CGPoint) -> Claim? {
        if groups.contains(where: { hypot(point.x - $0.middle.x, point.y - $0.middle.y) < $0.reach }) { return .buttons }
        if stick { return point.x < size.width / 2 ? .stick : nil }
        return hypot(point.x - home.x, point.y - home.y) < Self.pad * 1.6 ? .buttons : nil
    }

    /// Whether a finger landing at `point` is the controls'. The others are the game's pointer.
    func covers(_ point: CGPoint) -> Bool { claim(point) != nil }

    /// The way and how far a stick that landed at `base` is pushed by a thumb at `thumb`: no longer than 1, at `reach`.
    func pushed(from base: CGPoint, to thumb: CGPoint) -> Vector {
        let way: Vector = [thumb.x - base.x, thumb.y - base.y] / reach
        let length = (way * way).sum().squareRoot()
        return length > 1 ? way / length : way
    }

    /// Where the D-pad or the stick's home and the buttons are drawn, in the pixels of a `canvas` shown with its top-left
    /// corner at `origin`, `scale` points to a pixel: those parts of them over it, for `Input.touchControls`. The buttons
    /// from each corner give one, round all of them.
    func rectangles(over canvas: Size, at origin: CGPoint, scale: Double) -> [Rect] {
        let pad = CGRect(x: home.x - reach, y: home.y - reach, width: reach * 2, height: reach * 2)
        let corners = [TouchLayout.Corner.topLeft, .topRight, .bottomLeft, .bottomRight].compactMap { corner -> CGRect? in
            let boxes = layout.buttons.filter { $0.corner == corner }.map { place in
                let middle = middle(of: place)
                return CGRect(x: middle.x - place.radius, y: middle.y - place.radius, width: place.radius * 2, height: place.radius * 2)
            }
            return boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
        }
        return ([pad] + corners).compactMap { box in
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
            let code = GCKeyCode(rawValue: key.keyCode.rawValue)
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
    private var viewport: MTLViewport { fit(GameApp.resolution, in: bounds.size, top: safeAreaInsets.top) }

    /// Tells the game where the controls are over its canvas, `Input.touchControls`, as they show or move.
    private func report() {
        let (canvas, viewport) = (GameApp.resolution, viewport)
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
        let (canvas, viewport) = (GameApp.resolution, viewport)
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
