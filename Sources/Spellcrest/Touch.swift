import Foundation

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
