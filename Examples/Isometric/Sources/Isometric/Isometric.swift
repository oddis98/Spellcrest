import Spellcrest

@main struct Isometric: Game {
    var resolution: Size { Size(640, 360) }
    func start() -> Scene { Hall() }
}

/// A hall at night, seen from above at an angle as Witchbrook's rooms are. Its floor is a map of diamonds made from
/// text, and what stands on it, its walls, table, crates and fire, are objects from a second text, drawn in front of and
/// behind each other as they stand. The fire lights the floor, and the walls' feet more than their tops; the walls and
/// crates cast its shadows, and its light spills out of the door. Walk with the D-pad, or click or tap the floor: going
/// in, the hall's two near walls are cut down to sills so you can see in.
final class Hall: Scene {
    let player = Walker()
    var route: [Vector] = [] // where a click or a tap sent the player, round what's in the way
    var fires: [Fire] = []

    /// The floor, a cell a character: `#` boards, which the tileset says are the hall's (a tile's `room`), `,` grass and
    /// `:` a path of stones.
    static let floor = [String](repeating: ",,,,,,,,,,,,,,,,,,,,,,,,,,,,", count: 6)
        + [String](repeating: ",,,,,,,,,##########,,,,,,,,,", count: 8)
        + [String](repeating: ",,,,,,,,,,,,,,:,,,,,,,,,,,,,", count: 3)
        + [String](repeating: ",,,,,,,,,,,,,,,:,,,,,,,,,,,,", count: 2)
        + [String](repeating: ",,,,,,,,,,,,,,,,:,,,,,,,,,,,", count: 5)

    /// What stands on it, over the same cells: a wall along a cell's bottom (`_`), right (`>`), top (`^`) or left edge
    /// (`<`), a table `T` from its cell rightward, a crate `C`, the fire `F`, and where the player starts, `@`. Walls on
    /// a cell's top or left edge stand in front of the room above or left of them, so they're cut while the player is in
    /// it; posts fill the corners where walls meet.
    static let things = [String](repeating: "............................", count: 5) + [
        "........._________..........",
        "........>..........<........",
        "........>.T......CC<........",
        "........>.........C<........",
        "........>..........<........",
        "........>.....F....<........",
        "........>..........<........",
        "........>..........<........",
        "........>..........<........",
        ".........^^^^^.^^^^.........",
        "............................",
        "..............@.............",
    ] + [String](repeating: "............................", count: 7)

    override init() {
        super.init()
        // Each floor character one of a few tiles, by a hash of its cell, so the boards and the grass don't repeat.
        let variants: [Character: [Int]] = ["#": [0, 1, 2], ",": [3, 4, 5], ":": [6, 7]], letters = Array("abcdefgh")
        let rows = Self.floor.enumerated().map { row, line in
            String(line.enumerated().map { column, cell in
                variants[cell].map { letters[$0[(column * 7 + row * 13 + column * row) % $0.count]] } ?? cell
            })
        }
        var map = Tilemap(.floor, tileSize: 16, rows: rows, legend: Dictionary(uniqueKeysWithValues: letters.enumerated().map { ($1, $0) }), solid: [])
        map.projection = .isometric // its tiles are diamonds, 32 by 16, and its cells 16 pixels square on the floor
        tilemap = map
        background = 0x07090F
        (darkness, darknessColor) = (0.9, 0x141C3A) // night, a deep blue where the fire doesn't reach
        bloom = Bloom(strength: 0.8)
        follow = player
        build()
    }

    /// Adds what `things` puts on the floor, and a post where two walls meet at a corner.
    func build() {
        var xWalls: [(Rect, String?)] = [], yWalls: [(Rect, String?)] = []
        for (row, line) in Self.things.enumerated() {
            for (column, thing) in line.enumerated() {
                let (x, y) = (column * 16, row * 16)
                func wall(_ name: ObjectName, _ box: Rect, facing room: Vector?) {
                    let open = room.flatMap { self.room(under: $0) } // the room it's in front of, if it's in front of one
                    add(name, at: [Double(box.x), Double(box.y)], properties: open.map { ["room": $0] } ?? [:])
                    if name == .wallX { xWalls.append((box, open)) } else { yWalls.append((box, open)) }
                }
                switch thing {
                case "_": wall(.wallX, Rect(x: x, y: y + 12, width: 16, height: 4), facing: nil)
                case ">": wall(.wallY, Rect(x: x + 12, y: y, width: 4, height: 16), facing: nil)
                case "^": wall(.wallX, Rect(x: x, y: y, width: 16, height: 4), facing: [Double(x + 8), Double(y - 8)])
                case "<": wall(.wallY, Rect(x: x, y: y, width: 4, height: 16), facing: [Double(x - 8), Double(y + 8)])
                case "T": add(.table, at: [Double(x), Double(y)])
                case "C": add(.crate, at: [Double(x + 2), Double(y + 2)])
                case "F": if let fire = add(.fire, at: [Double(x), Double(y)]) as? Fire { fires.append(fire) }
                case "@": add(player, at: [Double(x + 4), Double(y + 4)])
                default: break
                }
            }
        }
        // A post in each corner a wall along x and one along y leave between their ends, cut with either of them.
        for (a, room) in xWalls {
            for (b, other) in yWalls where (b.x + 4 == a.x || b.x == a.x + 16) && (b.y == a.y + 4 || b.y + 16 == a.y) {
                add(.post, at: [Double(b.x), Double(a.y)], properties: (room ?? other).map { ["room": $0] } ?? [:])
            }
        }
    }

    override func update(_ dt: Double) {
        var way = Input.direction(in: self) // up the picture is up and left on the floor
        if Input.pressed(.pointer), let point = Input.pointer {
            route = player.path(to: projection.floor(under: point + camera), diagonals: true) ?? []
        }
        if way == .zero, !route.isEmpty {
            player.walk(dt, along: &route, speed: 48)
            way = player.velocity
        } else {
            route = [] // the D-pad takes over
            player.velocity = way * 48
            player.move(dt)
        }
        player.sprite?.play(way == .zero ? "stand" : "walk")
        player.sprite?.face(projection.picture(of: way)) // the nearest of eight ways across the picture
        bends = fires.map(\.haze)
        super.update(dt)
    }
}

/// The player, a villager drawn facing five ways, the three facing west their mirrors (`Sprite.facing`), standing on a
/// footprint 8 pixels square.
final class Walker: Entity {
    override init() {
        super.init()
        sprite = Sprite(.villager)
        sprite?.play("stand")
        sprite?.facing = .south
        hitbox = Rect(x: 0, y: 0, width: 8, height: 8)
        solid = true
    }
}

/// The hall's fire: flames glowing over a ring of stones, embers rising off it, and its light on the floor, which
/// flickers and which the walls and crates cast shadows from.
final class Fire: Entity, Placeable {
    /// Heat haze over its flames, where they are in the picture, as bends and the camera are in an isometric scene.
    var haze: Bend { Bend(.haze, at: spriteAt + [16, 2], radius: 9, strength: 0.6) }

    override init() {
        super.init()
        var flames = Sprite(.flames)
        flames.play("burn")
        flames.glows = true
        parts = [Part(flames, offset: [8, -9])] // standing in the ring
        light = Light(radius: 112, color: 0xFFA050, flicker: 0.12, shadows: true)
        emitter = Emitter(rate: 10, life: 0.8...1.6, speed: 6...16, angle: -.pi / 2, spread: 0.8, area: 3, gravity: [0, -12], drag: 1.2,
                          jitter: 10, colors: [0xFFE9A0, 0xFF9A3C, 0xC2401A])
    }
}
