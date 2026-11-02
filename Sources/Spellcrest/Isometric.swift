import Foundation

/// How a scene draws its world, which its map says (`Tilemap.projection`): flat, as it lies, or isometric, as
/// Witchbrook's is.
public enum Projection: Sendable, Equatable {
    /// The world as it lies, each of its pixels a pixel of the picture: platformers and top-down games.
    case flat
    /// The floor seen from above at an angle, in 2:1 pixel isometric: a map's cells are diamonds twice as wide as tall,
    /// and what stands on them stands up, drawn in front of and behind each other as they stand. A world pixel along the
    /// floor's x goes a pixel right and half a pixel down the picture, one along its y a pixel left and half down, and a
    /// pixel of height a pixel up.
    case isometric

    /// Where the world point `point`, on the floor, and `height` pixels above it, is drawn in the scene's picture, before
    /// its `camera` is taken off: to put something over an entity, like a name over a head. A way across the floor, like
    /// a velocity, turns into its way across the picture the same way.
    public func picture(of point: Vector, height: Double = 0) -> Vector {
        switch self {
        case .flat: [point.x, point.y - height]
        case .isometric: [point.x - point.y, (point.x + point.y) / 2 - height]
        }
    }

    /// The point on the floor that's drawn at `point` in the picture: where a tap lands is `floor(under: pointer + camera)`.
    public func floor(under point: Vector) -> Vector {
        switch self {
        case .flat: point
        case .isometric: [point.y + point.x / 2, point.y - point.x / 2]
        }
    }
}

/// One of the eight ways something faces in the picture, by the compass: north up the screen, east to its right. Its
/// raw value names the animation that faces it: "walk-se" for walking south-east (`Sprite.facing`).
public enum Direction: String, CaseIterable, Sendable {
    case north = "n", northEast = "ne", east = "e", southEast = "se", south = "s", southWest = "sw", west = "w", northWest = "nw"

    /// The nearest of the eight to `way`, a way across the picture, y down; south for none.
    public init(_ way: Vector) {
        guard way != .zero else { self = .south; return }
        let eighth = Int((atan2(way.y, way.x) / (.pi / 4)).rounded()) // 0 east, 2 south, -2 north
        self = [.east, .southEast, .south, .southWest, .west, .northWest, .north, .northEast][(eighth + 8) % 8]
    }

    /// The same way, mirrored left and right: south-west for south-east, and north and south as they are.
    var mirrored: Direction {
        switch self {
        case .north, .south: self
        case .northEast: .northWest
        case .east: .west
        case .southEast: .southWest
        case .southWest: .southEast
        case .west: .east
        case .northWest: .northEast
        }
    }
}

/// What stands in an isometric scene, as `isometricOrder` sorts it: a box on the floor, its footprint from x0, y0 to
/// x1, y1 in world pixels up to its `height`, and the part of the picture it's drawn over, which those it overlaps are
/// sorted against.
struct Standing {
    var footprint: SIMD4<Double>
    var height: Double
    var drawn: SIMD4<Double> // left, top, right and bottom in the picture

    /// How near the view its footprint's middle is: what's further down the picture, and so in front, is nearer.
    var nearness: Double { (footprint.x + footprint.z + footprint.y + footprint.w) / 2 }

    /// Whether it's behind `other` along an axis they're apart on: before it along the floor's x or y, or lying flat on
    /// the floor where the other stands. Nil when neither is behind the other, as when they stand in each other.
    func behind(_ other: Standing) -> Bool? {
        let (a, b) = (footprint, other.footprint)
        let before = a.z <= b.x || a.w <= b.y || height == 0 && other.height > 0
        let after = b.z <= a.x || b.w <= a.y || other.height == 0 && height > 0
        return before == after ? nil : before
    }
}

/// The order to draw `things` in so that each is drawn after those behind it that it overlaps in the picture, as boxes
/// standing apart on the floor are: of two that overlap, one is before the other along the floor's x or its y. Things
/// that stand in each other go by the nearness of their footprints' middles, as do those that don't overlap.
func isometricOrder(_ things: [Standing]) -> [Int] {
    let count = things.count
    // Those each one is drawn after, found by sweeping across the picture: each against those that start before it ends.
    let byLeft = things.indices.sorted { things[$0].drawn.x < things[$1].drawn.x }
    var after = [[Int]](repeating: [], count: count)
    for (k, i) in byLeft.enumerated() {
        let a = things[i]
        for j in byLeft[(k + 1)...] {
            let b = things[j]
            if b.drawn.x >= a.drawn.z { break }
            guard b.drawn.y < a.drawn.w, a.drawn.y < b.drawn.w else { continue }
            if a.behind(b) ?? ((a.nearness, i) < (b.nearness, j)) { after[j].append(i) } else { after[i].append(j) }
        }
    }
    // Depth first from the farthest, each drawn once all it's drawn after are; a cycle, which boxes standing apart don't
    // make, is broken where it's found.
    let start = things.indices.sorted { (things[$0].nearness, $0) < (things[$1].nearness, $1) }
    var order: [Int] = [], seen = [Bool](repeating: false, count: count)
    order.reserveCapacity(count)
    var stack: [(thing: Int, next: Int)] = []
    for first in start where !seen[first] {
        seen[first] = true
        stack.append((first, 0))
        while let (thing, next) = stack.last {
            if next < after[thing].count {
                stack[stack.count - 1].next += 1
                let behind = after[thing][next]
                if !seen[behind] {
                    seen[behind] = true
                    stack.append((behind, 0))
                }
            } else {
                order.append(thing)
                stack.removeLast()
            }
        }
    }
    return order
}

extension Entity {
    /// Where its sprite's top-left corner is drawn this frame, in the picture: at `drawnAt` in a flat scene; in an
    /// isometric one standing on its hitbox, which is its footprint on the floor there, its frame's bottom on the
    /// footprint's front corner and its middle over the footprint's middle. Its parts are drawn from here, at their
    /// offsets; draw what goes with it from here too.
    public var spriteAt: Vector {
        guard scene?.projection == .isometric else { return drawnAt }
        return pictured ?? standingCorner { frameSize($0) }
    }

    /// Where its sprite's top-left corner stands on its footprint in an isometric picture, its frame's size from `frame`:
    /// or without a sprite, where the footprint's own box in the picture would be.
    func standingCorner(_ frame: (String) -> Size?) -> Vector {
        let (width, depth) = (Double(hitbox.width), Double(hitbox.height))
        let size = drawnSprite.flatMap { frame($0.image) }.map { Vector(Double($0.width), Double($0.height)) } ?? [width + depth, (width + depth) / 2]
        let foot = drawnAt + [Double(hitbox.x), Double(hitbox.y)]
        let middle = foot + [width, depth] / 2, front = foot + [width, depth]
        return [middle.x - middle.y - size.x / 2, (front.x + front.y) / 2 - size.y]
    }

    /// The middle of its footprint where it's drawn, on the floor of an isometric scene: where its light shines from, and
    /// the room it's in.
    var footprintMiddle: Vector { drawnAt + [Double(hitbox.x), Double(hitbox.y)] + [Double(hitbox.width), Double(hitbox.height)] / 2 }

    /// The middle of its sprite as it's drawn in an isometric picture, or of its hitbox without one: where the camera
    /// follows it and its particles come out.
    func pictureMiddle(_ screen: Screen) -> Vector { spriteAt + screen.middle(of: self) - drawnAt }

    /// How near the view the middle of its footprint is, from where it is now, as halfway down the picture it'd be on
    /// the floor: where its particles go among the entities standing.
    var pictureDepth: Double {
        let middle = position + remainder + [Double(hitbox.x), Double(hitbox.y)] + [Double(hitbox.width), Double(hitbox.height)] / 2
        return (middle.x + middle.y) / 2
    }

    /// The sprite it's drawn with now: its own, or while the player is in the room it's a wall of, its object's `cut`
    /// image, as Witchbrook's rooms open: a wall cut down to a sill.
    var drawnSprite: Sprite? {
        guard cut, var sprite, let image = object?.sprite("cut") else { return sprite }
        sprite.image = image.name
        return sprite
    }

    /// How it stands in an isometric scene, its frames' sizes from `frame`: its footprint where it's drawn, as tall as
    /// its sprite and its parts reach above the footprint, and the part of the picture they're drawn over. It keeps
    /// where its sprite is drawn (`pictured`), which its drawing reads.
    func standing(_ frame: (String) -> Size?) -> Standing {
        let foot = drawnAt + [Double(hitbox.x), Double(hitbox.y)]
        let footprint = SIMD4(foot.x, foot.y, foot.x + Double(hitbox.width), foot.y + Double(hitbox.height))
        let deep = Double(hitbox.width + hitbox.height) / 2 // the footprint's own height in the picture
        let front = (footprint.z + footprint.w) / 2, middle = (footprint.x + footprint.z - footprint.y - footprint.w) / 2
        var drawn = SIMD4(middle - deep, front - deep, middle + deep, front) // the footprint, if it draws nothing
        let corner = standingCorner(frame)
        func reach(_ image: String, at offset: Vector) {
            guard let size = frame(image) else { return }
            let at = corner + offset
            drawn = SIMD4(min(drawn.x, at.x), min(drawn.y, at.y), max(drawn.z, at.x + Double(size.width)), max(drawn.w, at.y + Double(size.height)))
        }
        if let sprite = drawnSprite { reach(sprite.image, at: .zero) }
        for part in parts { reach(part.sprite.image, at: part.offset) }
        pictured = corner
        return Standing(footprint: footprint, height: max(0, front - deep - drawn.y), drawn: drawn)
    }
}

extension Scene {
    /// The room a point on the floor is in, in world pixels, which an isometric scene opens the walls of while the entity
    /// it follows is in it: the `room` property of one of its map's zones there, an object without a sprite, or else of
    /// the floor's tile there, the topmost layer's first; nil outside every room. A wall is an object whose `room` names
    /// the room it's a wall of, and whose `cut` sprite is drawn in place of its own while the room's open.
    public func room(under point: Vector) -> String? {
        guard let map = tilemap else { return nil }
        if let zone = map.objects.first(where: { $0.sprite == nil && $0.parts.isEmpty && $0.box.contains(point) && $0.text("room") != nil }) {
            return zone.text("room")
        }
        return map.layers.indices.reversed().lazy.compactMap { map.properties(at: point, layer: $0).text("room") }.first
    }
}

extension Tilemap {
    /// The cells of an isometric map whose tiles, frames of `frame`'s size standing on their diamonds, or the diamonds
    /// alone, show any of the picture from `left`, `top` to `right`, `bottom`: from the back of the picture to its front,
    /// as they're drawn. A cell's diamond is a cell wide each side of x = (column - row) * cell, its bottom at
    /// (column + row + 2) * cell / 2.
    func isometricCells(left: Double, top: Double, right: Double, bottom: Double, frame: Size? = nil) -> [(column: Int, row: Int)] {
        let cell = Double(tileSize), (wide, tall) = (Double(frame?.width ?? tileSize * 2), Double(frame?.height ?? tileSize))
        let sums = Int((2 * top / cell).rounded(.down)) - 2 ... Int((2 * (bottom + tall) / cell).rounded(.up)) - 2
        let differences = Int(((left - wide / 2) / cell).rounded(.down)) ... Int(((right + wide / 2) / cell).rounded(.up))
        var cells: [(column: Int, row: Int)] = []
        for sum in sums where sum >= 0 && sum <= width + height - 2 {
            for difference in differences where (sum - difference) & 1 == 0 {
                let (column, row) = ((sum + difference) / 2, (sum - difference) / 2)
                if (0..<width).contains(column), (0..<height).contains(row) { cells.append((column, row)) }
            }
        }
        return cells
    }
}
