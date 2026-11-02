import Carbon.HIToolbox
import Foundation
import Metal
import SpellcrestProtocol
import Testing
@testable import Spellcrest

@Test func aPointOnTheFloorIsDrawnHalfAsFarDownAsAcrossAndComesBack() {
    let iso = Projection.isometric
    #expect(iso.picture(of: [16, 0]) == [16, 8] && iso.picture(of: [0, 16]) == [-16, 8]) // a cell's right and left corners
    #expect(iso.picture(of: [16, 16], height: 10) == [0, 6]) // its front corner, 10 up
    for point: Vector in [[0, 0], [37, 5], [-12, 40.5], [200, 3]] {
        let back = iso.floor(under: iso.picture(of: point))
        #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
    }
    #expect(Projection.flat.picture(of: [3, 4]) == [3, 4] && Projection.flat.floor(under: [3, 4]) == [3, 4])
}

/// How a box stands, as the scene works it out for an entity with a frame of `frame` on a footprint at `at`.
@MainActor func standing(_ footprint: Rect, at position: Vector, frame: Size) -> Standing {
    let scene = Scene()
    var map = Tilemap("none", tileSize: 16, rows: [], legend: [:])
    map.projection = .isometric
    scene.tilemap = map
    let thing = Entity()
    thing.sprite = Sprite("thing")
    thing.hitbox = footprint
    scene.add(thing, at: position)
    return thing.standing { _ in frame }
}

@MainActor @Test func whatStandsInFrontIsDrawnAfterItRoundALongTableAndAWallsEnd() {
    // A table 64 by 16 and 12 tall, and a wall's end, 48 by 4 and 40 tall, with someone 8 by 8 in each of the eight
    // places round them, and by a long side's far end, where sorting by the footprints' middles goes wrong.
    for (thing, frame, places) in [(Rect(x: 0, y: 0, width: 64, height: 16), Size(80, 52),
                                    [[32, -8], [72, -8], [72, 8], [72, 24], [32, 24], [-8, 24], [-8, 8], [-8, -8], [58, -8], [6, 24]] as [Vector]),
                                   (Rect(x: 0, y: 0, width: 48, height: 4), Size(52, 66), [[44, -8], [56, -8], [56, 2], [56, 12], [44, 12], [32, 12], [52, -12]])] {
        let it = standing(thing, at: .zero, frame: frame)
        var overlapping = 0
        for place in places {
            let person = standing(Rect(x: 0, y: 0, width: 8, height: 8), at: place - [4, 4], frame: Size(16, 44))
            #expect(it.height == 12 || it.height == 40)
            guard person.drawn.x < it.drawn.z, it.drawn.x < person.drawn.z, person.drawn.y < it.drawn.w, it.drawn.y < person.drawn.w else { continue }
            overlapping += 1
            let inFront = person.footprint.x >= it.footprint.z || person.footprint.y >= it.footprint.w
            #expect(isometricOrder([it, person]) == (inFront ? [0, 1] : [1, 0]), "at \(place)")
            #expect(isometricOrder([person, it]) == (inFront ? [1, 0] : [0, 1]), "at \(place)")
        }
        #expect(overlapping >= 5)
    }
    // Lying flat on the floor, like a rug, is behind what stands on it; and three in a row, each before the next.
    let rug = standing(Rect(x: 0, y: 0, width: 32, height: 32), at: .zero, frame: Size(64, 32)), person = standing(Rect(x: 0, y: 0, width: 8, height: 8), at: [12, 12], frame: Size(16, 44))
    #expect(rug.height == 0 && isometricOrder([person, rug]) == [1, 0])
    let row = [standing(Rect(x: 0, y: 0, width: 16, height: 4), at: [32, 0], frame: Size(20, 58)),
               standing(Rect(x: 0, y: 0, width: 16, height: 4), at: [0, 0], frame: Size(20, 58)),
               standing(Rect(x: 0, y: 0, width: 16, height: 4), at: [16, 0], frame: Size(20, 58))]
    #expect(isometricOrder(row) == [1, 2, 0])
}

@MainActor @Test func anIsometricMapsCellsInViewGoFromTheBackOfThePictureToItsFront() {
    var map = Tilemap("none", tileSize: 16, rows: Array(repeating: "##########", count: 10), legend: ["#": 0])
    map.projection = .isometric
    #expect(map.picture == Rect(x: -160, y: 0, width: 320, height: 160)) // its diamond's box
    let cells = map.isometricCells(left: -16, top: 0, right: 16, bottom: 24)
    #expect(cells.first! == (0, 0) && cells.contains { $0 == (1, 1) } && !cells.contains { $0 == (5, 5) })
    let sums = cells.map { $0.column + $0.row }
    #expect(sums == sums.sorted()) // the back first
    // A tile taller than its diamond reaches up into the view from below it.
    let tall = map.isometricCells(left: -16, top: 0, right: 16, bottom: 24, frame: Size(32, 64))
    #expect(tall.count > cells.count && tall.contains { $0 == (3, 3) })
}

@MainActor @Test func upOnTheDPadGoesUpThePictureAndADiagonalAlongTheFloorsEdge() {
    let scene = Scene()
    var map = Tilemap("none", tileSize: 16, rows: ["#"], legend: ["#": 0])
    map.projection = .isometric
    scene.tilemap = map
    func way(_ keys: Set<Int>) -> Vector {
        (Input.keys, Input.pushed) = ([], [])
        Input.poll()
        Input.keys = keys
        Input.poll()
        defer { Input.keys = []; Input.poll() }
        return Input.direction(in: scene)
    }
    let up = way([kVK_UpArrow]), half = 0.5.squareRoot()
    #expect(abs(up.x + half) < 1e-9 && abs(up.y + half) < 1e-9) // up and left on the floor
    #expect(abs(Projection.isometric.picture(of: up).x) < 1e-9) // which is straight up the picture
    let upRight = way([kVK_UpArrow, kVK_RightArrow])
    #expect(abs(upRight.x) < 1e-9 && abs(upRight.y + 1) < 1e-9) // along the floor's y, its edge
    scene.tilemap?.projection = .flat
    #expect(way([kVK_UpArrow]) == [0, -1])
}

@MainActor @Test func aSpriteFacesTheNearestOfEightWaysAndMirrorsThoseNotDrawn() throws {
    #expect(Direction([1, 0]) == .east && Direction([1, 0.4]) == .east && Direction([1, 0.5]) == .southEast && Direction([0, -1]) == .north)
    #expect(Direction([-1, -1]) == .northWest && Direction([-1, 0.1]) == .west && Direction(.zero) == .south)
    var sprite = Sprite("walker")
    sprite.face([0, 0]) // standing still faces as it did
    #expect(sprite.facing == nil)
    sprite.face([-3, 2])
    #expect(sprite.facing == .southWest)

    let screen = try canvas(Size(16, 8))
    screen.textures["walker"] = try texture(.init(repeating: 0xFFFF_FFFF, count: 64), width: 16) // four frames of 4 by 4
    screen.sheets["walker"] = SheetFile(frameWidth: 4, frameHeight: 4, animations: ["walk": .init(frames: [0], fps: 0),
        "walk-se": .init(frames: [1], fps: 0), "walk-e": .init(frames: [2], fps: 0), "walk-n": .init(frames: [3], fps: 0)])
    func drawn(_ facing: Direction?) -> (u0: Float, u1: Float) {
        var walker = Sprite("walker")
        walker.play("walk")
        walker.facing = facing
        (screen.vertices, screen.batch) = ([], nil)
        screen.draw(walker, x: 0, y: 0)
        return (screen.vertices[0][2], screen.vertices[5][2]) // the first corner's u, and its right one's
    }
    #expect(drawn(nil) == (0, 0.25) && drawn(.southEast) == (0.25, 0.5) && drawn(.east) == (0.5, 0.75))
    #expect(drawn(.southWest) == (0.5, 0.25) && drawn(.west) == (0.75, 0.5)) // mirrored
    #expect(drawn(.north) == (0.75, 1) && drawn(.south) == (0, 0.25)) // not drawn: the plain animation
}

/// An isometric scene of one white wall, 16 by 4 on the floor and 24 tall, standing at (0, 16) in the dark, and an
/// assets folder for its tileset and its wall's cut image.
@MainActor func darkHall(_ screen: Screen) throws -> (Scene, Entity) {
    screen.textures["wall"] = try texture(.init(repeating: 0xFFFF_FFFF, count: 20 * 34), width: 20) // (16 + 4) by (10 + 24)
    screen.sheets["wall"] = .some(nil)
    let diamond = (0..<(32 * 16)).map { (i: Int) -> UInt32 in // white
        let (x, y) = (abs(Double(i % 32) + 0.5 - 16) / 16, abs(Double(i / 32) + 0.5 - 8) / 8)
        return x + y <= 1 ? 0xFFFF_FFFF : 0
    }
    screen.textures["floor"] = try texture(diamond, width: 32)
    screen.sheets["floor"] = .some(nil)
    let scene = Scene()
    var map = Tilemap("floor", tileSize: 16, rows: Array(repeating: "####", count: 4), legend: ["#": 0], solid: [])
    map.projection = .isometric
    scene.tilemap = map
    scene.darkness = 1
    let wall = Entity()
    wall.sprite = Sprite("wall")
    wall.hitbox = Rect(x: 0, y: 0, width: 16, height: 4)
    (wall.solid, wall.opaque) = (true, true)
    scene.add(wall, at: [16, 16])
    scene.camera = [-40, -20]
    return (scene, wall)
}

@MainActor @Test func whatStandsIsLitByTheFloorUnderItLessUpItAndNotFromBehindItsWall() throws {
    let screen = try canvas(Size(120, 90))
    let (scene, wall) = try darkHall(screen)
    // Its face toward the floor's y, the left one in the picture, from 4 pixels in at its bottom to its top.
    let corner = Projection.isometric.picture(of: [16, 20]) - scene.camera // where its front's left foot is
    func brightness(_ pixels: [UInt32], up: Int) -> Int {
        let (x, y) = (Int(corner.x) + 4, Int(corner.y) + 1 - up) // 4 along it, `up` pixels over its foot
        return Int(pixels[y * 120 + x] >> 8 & 0xFF)
    }
    scene.lamps = [Lamp(at: [24, 32], light: Light(radius: 40, shadows: true))] // in front of it, on the floor
    let lit = try render(screen) { scene.draw(screen) }
    #expect(brightness(lit, up: 0) > 0x80 && brightness(lit, up: 0) > brightness(lit, up: 20) + 8) // brighter at its foot than up it
    #expect(brightness(lit, up: 20) > 0x20)
    scene.lamps = [Lamp(at: [24, 8], light: Light(radius: 40, shadows: true))] // behind it, as far away
    let behind = try render(screen) { scene.draw(screen) }
    #expect(brightness(behind, up: 0) < 0x10 && brightness(behind, up: 20) < 0x10) // the wall stops it
    // The floor's lit round a lamp as an ellipse twice as wide as tall, as a round light on the floor is drawn.
    scene.remove(wall)
    scene.lamps = [Lamp(at: [24, 8], light: Light(radius: 40))]
    let floor = try render(screen) { scene.draw(screen) }, middle = Projection.isometric.picture(of: [24, 8]) - scene.camera
    func at(_ dx: Int, _ dy: Int) -> Int { Int(floor[(Int(middle.y) + dy) * 120 + Int(middle.x) + dx] >> 8 & 0xFF) }
    // As far across the floor, 14 and 28 pixels from it: each texel's light is its middle's, which is half a pixel
    // further down the picture, so a little further away on the floor, for the one below.
    #expect(abs(at(-20, 0) - at(0, 10)) < 12 && abs(at(-40, 0) - at(0, 20)) < 12 && at(0, 20) > 0x20)
    #expect(at(-60, 0) < 4 && at(0, 30) < 4) // past its radius, 42 pixels away
}

@MainActor @Test func aWallIsCutWhileTheEntityTheSceneFollowsIsInItsRoom() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "hall-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path)
    try SheetFile(frameWidth: 32, frameHeight: 16, properties: [.init(name: "room")], tiles: [1: ["room": "hall"]]).write(to: assets.appending(path: "floor.json"))
    let screen = try canvas(Size(80, 60))
    screen.textures["wall-cut"] = try texture(.init(repeating: 0xFFFF_FFFF, count: 20 * 18), width: 20)
    screen.sheets["wall-cut"] = .some(nil)
    let (scene, _) = try darkHall(screen)
    scene.tilemap = Tilemap("floor", tileSize: 16, rows: ["##..", "##..", "....", "...."], legend: ["#": 1, ".": 0], solid: [])
    scene.tilemap?.projection = .isometric
    #expect(scene.room(under: [8, 8]) == "hall" && scene.room(under: [40, 40]) == nil)
    let placed = TilemapFile.Object(name: "wall", x: 0, y: 32, properties: ["room": "hall", "cut": "wall-cut"])
    let wall = Entity(Tilemap.Object(placed, definition: nil, tileSize: 16, projection: .isometric) { _ in nil })
    wall.sprite = Sprite("wall")
    wall.hitbox = Rect(x: 0, y: 0, width: 16, height: 4)
    scene.add(wall, at: [0, 32])
    let player = Entity()
    player.hitbox = Rect(x: 0, y: 0, width: 8, height: 8)
    scene.add(player, at: [40, 40])
    scene.follow = player
    _ = try render(screen) { scene.draw(screen) }
    #expect(wall.drawnSprite?.image == "wall")
    player.position = [8, 8] // in the hall, behind the wall
    _ = try render(screen) { scene.draw(screen) }
    #expect(wall.drawnSprite?.image == "wall-cut" && wall.sprite?.image == "wall") // drawn cut, as it is
    #expect(scene.isometricOrder(screen).stands.contains { $0.height == 8 }) // and as tall as the cut image stands
}
