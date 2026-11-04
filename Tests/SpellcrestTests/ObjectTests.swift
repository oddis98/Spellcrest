import Foundation
import Metal
import SpellcrestProtocol
import Synchronization
import Testing
@testable import Spellcrest

@MainActor @Test func assetsAreFoundByNameInTheirFoldersAtTheTopFirstAndWhenAddedOrMoved() throws {
    let game = FileManager.default.temporaryDirectory.appending(path: "assets-\(UUID())")
    for path in ["Sprites/Enemies/bat.png", "Sprites/slime.png", "slime.png", "Maps/b/level.tilemap", "Maps/a/level.tilemap", ".hidden/x.png",
                 "Parts/hat/bat.png"] {
        try FileManager.default.createDirectory(at: game.appending(path: "Assets/\(path)").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: game.appending(path: "Assets/\(path)"))
    }
    FileManager.default.changeCurrentDirectoryPath(game.path) // games load Assets/ relative to here
    #expect(assetURL("bat.png").path.hasSuffix("/Assets/Sprites/Enemies/bat.png")) // not the kit's part of that name
    #expect(assetURL("slime.png").path.hasSuffix("/Assets/slime.png")) // at the top first
    #expect(assetURL("level.tilemap").path.hasSuffix("/Assets/Maps/a/level.tilemap")) // then the first by path,
    #expect(assetIndex.withLock { $0.warned.contains("level.tilemap") }) // which the console mentions
    #expect(assetURL("x.png").path.hasSuffix("/Assets/x.png")) // hidden folders are the editor's

    try FileManager.default.createDirectory(at: game.appending(path: "Assets/Sounds"), withIntermediateDirectories: true)
    try Data().write(to: game.appending(path: "Assets/Sounds/coin.wav"))
    #expect(assetURL("coin.wav").path.hasSuffix("/Assets/coin.wav")) // looked for again at most once a second
    assetIndex.withLock { $0.checked = .distantPast }
    #expect(assetURL("coin.wav").path.hasSuffix("/Assets/Sounds/coin.wav"))
    try FileManager.default.moveItem(at: game.appending(path: "Assets/Sprites/Enemies/bat.png"), to: game.appending(path: "Assets/Sprites/bat.png"))
    assetIndex.withLock { $0.checked = .distantPast }
    #expect(assetURL("bat.png").path.hasSuffix("/Assets/Sprites/bat.png")) // moved while the game runs
}

@Test func filesAreReadOnceInAnAppAndEachTimeWhereTheyCanChange() {
    let kept = Mutex<[String: Int]>([:])
    var reads = 0
    func read() -> Int {
        reads += 1
        return reads
    }
    #expect(once("a", in: kept, keeping: true, read) == 1 && once("a", in: kept, keeping: true, read) == 1) // in an app
    #expect(once("b", in: kept, keeping: true, read) == 2 && once("a", in: kept, keeping: false, read) == 3) // in the editor
}

@Test func objectFilesRoundTripAndAnEmptyOneIsAMarker() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "villager-\(UUID()).object")
    try Data("{}".utf8).write(to: file)
    #expect(try ObjectFile(contentsOf: file) == ObjectFile())
    let villager = ObjectFile(sprite: "villager", animation: "idle", hitbox: .init(x: 3, y: 10, width: 10, height: 6), solid: true, class: "Villager",
                              properties: [.init(name: "name", value: "Ann"), .init(name: "to", type: .map), .init(name: "speed", type: .number, value: "40")])
    try villager.write(to: file)
    #expect(try ObjectFile(contentsOf: file) == villager)
    #expect(try String(contentsOf: file, encoding: .utf8).contains(#""class":"Villager""#))
}

@MainActor @Test func placedObjectsGetTheirDefinitionsSizeHitboxSpriteClassAndDefaults() {
    let frames = ["tree": Size(32, 48), "coin": Size(8, 8)]
    func object(_ placed: TilemapFile.Object, _ definition: ObjectFile?) -> Tilemap.Object {
        Tilemap.Object(placed, definition: definition, tileSize: 16) { frames[$0] }
    }
    let tree = object(.init(name: "oak", x: 4, y: 8), ObjectFile(sprite: "tree", animation: "sway", hitbox: .init(x: 11, y: 38, width: 10, height: 8),
                                                                    solid: true, class: "Tree"))
    #expect(tree.box == Rect(x: 4, y: 8, width: 32, height: 48) && tree.hitbox == Rect(x: 11, y: 38, width: 10, height: 8))
    #expect(tree.solid && tree.class == "Tree" && tree.sprite?.image == "tree" && tree.sprite?.animation == "sway")

    // A zone is its own size, or one tile, unless the map sized it; its hitbox is all of it.
    let door = ObjectFile(width: 16, height: 4, properties: [.init(name: "to", type: .map), .init(name: "locked", type: .toggle, value: "true"),
                                                             .init(name: "speed", type: .number, value: "40")])
    let placed = object(.init(name: "door", x: 0, y: 0, properties: ["to": "house", "speed": "12.5", "note": "x"], width: 32), door)
    #expect(placed.box == Rect(x: 0, y: 0, width: 32, height: 4) && placed.hitbox == Rect(x: 0, y: 0, width: 32, height: 4))
    #expect(placed.sprite == nil && !placed.solid && placed.class == nil)
    #expect(placed.properties == ["to": "house", "locked": "true", "speed": "12.5", "note": "x"]) // its own over the defaults
    #expect(placed.double("speed") == 12.5 && placed.double("to") == nil && placed.bool("locked") && !placed.bool("open"))
    #expect(object(.init(name: "start", x: 0, y: 0), ObjectFile()).box == Rect(x: 0, y: 0, width: 16, height: 16)) // a marker

    // Without a definition, as in older maps: the image named after it, or one tile, and nothing to make.
    let coin = object(.init(name: "coin", x: 1, y: 2, properties: ["value": "5"]), nil)
    #expect(coin.box == Rect(x: 1, y: 2, width: 8, height: 8) && coin.sprite == nil && coin.class == nil && coin.properties == ["value": "5"])
    #expect(object(.init(name: "spot", x: 0, y: 0), nil).box.width == 16)
}

/// Made from objects that name it: its own `init()` runs, then it gets the object's sprite, hitbox and properties.
final class Bat: Entity, Placeable {
    var madeByInit = false
    lazy var speed = object?.double("speed") ?? 1

    override init() {
        super.init()
        madeByInit = true
        sprite = Sprite("own")
        hitbox = Rect(x: 0, y: 0, width: 1, height: 1)
    }
}

final class Stone: Entity {} // not Placeable

@MainActor @Test func addObjectsMakesEachAsItsClassOrAnEntityAndLeavesZonesAndMarkers() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "objects-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets.appending(path: "Objects"), withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try SheetFile(frameWidth: 8, frameHeight: 8).write(to: assets.appending(path: "tiles.json"))
    let definitions = [
        "bat": ObjectFile(sprite: "bat", hitbox: .init(x: 2, y: 2, width: 4, height: 4), class: "Bat", properties: [.init(name: "speed", type: .number, value: "20")]),
        "rock": ObjectFile(sprite: "rock", solid: true), "door": ObjectFile(width: 16, height: 4), "start": ObjectFile(),
        "ghost": ObjectFile(sprite: "ghost", class: "Ghost"), "stone": ObjectFile(class: "Stone"),
    ]
    for (name, definition) in definitions { try definition.write(to: assets.appending(path: "Objects/\(name).object")) }
    let names = ["bat", "rock", "door", "start", "ghost", "stone", "tree"] // the tree has no definition
    try TilemapFile(tileset: "tiles", width: 4, height: 4, layers: [.init(name: "Ground", tiles: .init(repeating: -1, count: 16))],
                    objects: names.enumerated().map { .init(name: $1, x: $0 * 8, y: 0, properties: $1 == "bat" ? ["speed": "30"] : nil) })
        .write(to: assets.appending(path: "level.tilemap"))

    let module = Scene.module
    Scene.module = "SpellcrestTests"
    defer { Scene.module = module }
    let scene = Scene()
    scene.tilemap = Tilemap("level")
    let made = scene.addObjects()
    #expect(made.map(\.position.x) == [0, 8, 32, 40] && scene.entities.count == 4 && scene.tilemap?.objects.count == 7)
    let bat = try #require(made[0] as? Bat)
    #expect(bat.madeByInit && bat.sprite?.image == "bat" && bat.hitbox == Rect(x: 2, y: 2, width: 4, height: 4) && bat.speed == 30)
    #expect(type(of: made[1]) == Entity.self && made[1].sprite?.image == "rock" && made[1].solid && made[1].object?.name == "rock")
    #expect(type(of: made[2]) == Entity.self && made[2].sprite?.image == "ghost" && Scene.warned.contains("Ghost")) // missing
    #expect(type(of: made[3]) == Entity.self && Scene.warned.contains("Stone")) // not Placeable

    let rock = assets.appending(path: "Objects/rock.object") // changed in the editor while the game runs
    try ObjectFile(sprite: "boulder").write(to: rock)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: rock.path)
    scene.tilemap?.reloadIfChanged()
    #expect(scene.tilemap?.objects[1].sprite?.image == "boulder" && scene.tilemap?.objects[1].solid == false)
}

@MainActor @Test func objectsMadeInCodeAreMadeFromTheirDefinitions() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "made-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets.appending(path: "Objects"), withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try ObjectFile(sprite: "bat", hitbox: .init(x: 2, y: 2, width: 4, height: 4), solid: true, class: "Bat",
                   properties: [.init(name: "speed", type: .number, value: "20")]).write(to: assets.appending(path: "Objects/bat.object"))
    let module = Scene.module
    Scene.module = "SpellcrestTests"
    defer { Scene.module = module }
    let scene = Scene()
    let bat = try #require(scene.add(ObjectName("bat"), at: [24, 8], properties: ["speed": "30"]) as? Bat)
    #expect(scene.entities.count == 1 && bat.scene === scene && bat.position == [24, 8] && bat.object?.position == [24, 8])
    #expect(bat.madeByInit && bat.sprite?.image == "bat" && bat.solid && bat.hitbox == Rect(x: 2, y: 2, width: 4, height: 4) && bat.speed == 30)
    let missing = scene.add("nothing", at: .zero) // no definition: an empty Entity, and a word in the console
    #expect(type(of: missing) == Entity.self && missing.sprite == nil && Scene.warned.contains("nothing.object") && scene.entities.count == 2)
}

// As the editor writes them in a game's AssetNames.swift.
extension ImageName { static let dot = ImageName("dot"), tiles = ImageName("tiles"), tiny = ImageName("tiny") }
extension MapName { static let level = MapName("level") }
extension SoundName { static let a = SoundName("a"), b = SoundName("b") }
extension ObjectName { static let door = ObjectName("door") }

@MainActor @Test func assetNamesDoWhatTheirStringsDo() throws {
    let assets = try silentTracks().appending(path: "Assets") // a.wav and b.m4a, the current directory's
    try SheetFile(frameWidth: 8, frameHeight: 8).write(to: assets.appending(path: "tiles.json"))
    try ObjectFile(width: 16, height: 8).write(to: assets.appending(path: "door.object"))
    try TilemapFile(tileset: "tiles", width: 2, height: 1, layers: [.init(name: "Ground", tiles: [0, -1])],
                    objects: [.init(name: "door", x: 8, y: 0), .init(name: "start", x: 0, y: 0)]).write(to: assets.appending(path: "level.tilemap"))
    let map = Tilemap(.level)
    #expect(map.layers == Tilemap("level").layers && map.objects(named: .door) == [[8, 0]] && map.objects(named: "door") == [[8, 0]])
    #expect(map.objects[0].name == .door && map.objects[1].name != .door && map.objects.filter { $0.name == .door }.count == 1)
    #expect(Sprite(.dot).image == "dot" && Tilemap(.tiles, tileSize: 8, rows: ["#"], legend: ["#": 0]).layers == [[0]])

    Music.volume = 0
    defer { Music.stop(); Music.volume = 1 }
    Music.play(.a, fade: 0)
    #expect(Music.track == .a && musicPlayer()?.url?.lastPathComponent == "a.wav")
    Sound.read = [:] // what other tests' folders had of the same name
    Sound.play(.b, volume: 0)
    #expect(Sound.read["b"]?.url.lastPathComponent == "b.m4a")

    let screen = Screen(size: Size(8, 8), gpu: try #require(systemGPU()), format: .bgra8)
    let texture = try texture([UInt32](repeating: 0, count: 9), width: 3)
    (screen.textures["dot"], screen.sheets["dot"], screen.textures["tiny"]) = (texture, .some(nil), texture)
    (screen.sheets["tiny"], screen.fonts["tiny"]) = (SheetFile(frameWidth: 1, frameHeight: 1, characters: "A"), Font(glyph: Size(1, 1), characters: "A", columns: [0...0]))
    func drawn(_ draw: () -> Void) -> [SIMD4<Float>] {
        screen.vertices = []
        draw()
        return screen.vertices
    }
    let box = Rect(x: 1, y: 1, width: 6, height: 5)
    #expect(drawn { screen.draw(.dot, x: 1, y: 2) } == drawn { screen.draw("dot", x: 1, y: 2) })
    #expect(drawn { screen.panel(.dot, in: box) } == drawn { screen.panel("dot", in: box) })
    let text = drawn { screen.text("A A", x: 0, y: 0, width: 2, font: .tiny) }
    #expect(text.count == 60 && text == drawn { screen.text("A A", x: 0, y: 0, width: 2, font: "tiny") })
    #expect(screen.textSize("A A", font: .tiny) == screen.textSize("A A", font: "tiny") && screen.wrap("A A", width: 2, font: .tiny) == "A\nA")
}

@Test func propertiesReadAsWhatTheyAreAndAnEmptyOneOverADefaultIsNone() {
    let definition = ObjectFile(properties: [.init(name: "to", type: .map, value: "house"), .init(name: "at", type: .object, value: "porch")])
    let door = Tilemap.Object(.init(name: "door", x: 0, y: 0, properties: [
        "at": "", "tint": "#FF004D", "speed": "40", "open": "true", "target": "12, 34", "icon": "key", "step": "creak",
        "words": "Hello!\nBye", "path": "0,0\n16,8\nnowhere", "bad": "#zz",
    ]), definition: definition, tileSize: 16) { _ in nil }
    #expect(door.map("to") == MapName("house") && door.object("at") == nil) // its own None over the default, porch
    #expect(door.color("tint") == 0xFF004D && door.color("speed") == nil && door.color("bad") == nil)
    #expect(door.double("speed") == 40 && door.bool("open") && door.point("target") == [12, 34] && door.point("speed") == nil)
    #expect(door.sprite("icon") == ImageName("key") && door.sound("step") == SoundName("creak") && door.map("nothing") == nil)
    #expect(door.list("words", of: String.self) == ["Hello!", "Bye"] && door.list("path", of: Vector.self) == [[0, 0], [16, 8]])
    #expect(door.list("tint", of: UInt32.self) == [0xFF004D] && door.list("speed", of: Int.self) == [40] && door.list("at", of: ObjectName.self).isEmpty)
    #expect(door.int("speed") == 40 && door.int("target") == nil && door.text("icon") == "key" && door.text("at") == nil && door.text("none") == nil)
    #expect(Int(property: "3.0") == 3 && Int(property: "2.5") == nil && Int(property: "three") == nil) // whole numbers, as `int` reads them
}

@MainActor @Test func tilesHaveTheirTilesetsPropertiesOverItsDefaults() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "tiles-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try SheetFile(frameWidth: 8, frameHeight: 8, properties: [.init(name: "water", type: .toggle), .init(name: "damage", type: .number, value: "0")],
                  tiles: [1: ["water": "true"], 2: ["damage": "5"]]).write(to: assets.appending(path: "tiles.json"))
    try TilemapFile(tileset: "tiles", width: 3, height: 1, layers: [.init(name: "Ground", tiles: [0, 1, -1]), .init(name: "Top", tiles: [-1, 2, -1])])
        .write(to: assets.appending(path: "level.tilemap"))
    let map = Tilemap("level")
    #expect(map.properties(at: [3, 3], layer: 0).properties == ["damage": "0"]) // tile 0 has the defaults
    #expect(map.properties(at: [8, 0], layer: 0).bool("water") && map.properties(at: [8, 0], layer: 0).double("damage") == 0)
    #expect(map.properties(at: [15, 7], layer: 1).double("damage") == 5 && !map.properties(at: [15, 7], layer: 1).bool("water"))
    #expect(map.properties(at: [16, 0], layer: 0).properties.isEmpty && map.properties(at: [-1, 0], layer: 0).properties.isEmpty) // empty, outside
}

@MainActor @Test func anObjectsPartsDrawWithItByDepthAndThoseAboveOverEverything() throws {
    let definition = ObjectFile(sprite: "dot", hitbox: .init(x: 0, y: 2, width: 3, height: 1),
                                parts: [.init(sprite: "dot", animation: "sway", x: 0, y: -3), .init(sprite: "dot", x: 1, y: -6, above: true)])
    let tree = Entity(Tilemap.Object(.init(name: "tree", x: 10, y: 10), definition: definition, tileSize: 16) { _ in Size(3, 3) })
    #expect(tree.parts.map(\.offset) == [[0, -3], [1, -6]] && tree.parts.map(\.above) == [false, true] && tree.parts[0].sprite.animation == "sway")
    let player = Entity()
    (player.sprite, player.hitbox) = (Sprite("dot"), Rect(x: 0, y: 0, width: 3, height: 3))
    let scene = Scene()
    scene.ySort = true
    scene.add(player, at: [20, 11]) // its feet at 14, in front of the tree's, at 13
    scene.add(tree, at: [10, 10])
    scene.update(0.5)
    #expect(tree.parts.allSatisfy { $0.sprite.time == 0.5 })

    let screen = Screen(size: Size(32, 32), gpu: try #require(systemGPU()), format: .bgra8)
    (screen.textures["dot"], screen.sheets["dot"]) = (try texture([UInt32](repeating: 0, count: 9), width: 3), .some(nil))
    scene.draw(screen)
    let corners = stride(from: 0, to: screen.vertices.count, by: 30).map { [screen.vertices[$0][0], screen.vertices[$0][1]] } // each quad's first corner
    #expect(corners == [[10, 10], [10, 7], [20, 11], [11, 4]]) // the tree and its part by depth, the player in front, the crown over all
}

@Test func filesFromBeforeTheNewFieldsLoad() throws {
    let sheet = try JSONDecoder().decode(SheetFile.self, from: Data(#"{"frameWidth": 8, "frameHeight": 8, "solid": [1]}"#.utf8))
    #expect(sheet.properties == nil && sheet.tiles == nil && sheet.properties(of: 1).isEmpty)
    let object = try JSONDecoder().decode(ObjectFile.self, from: Data(#"{"sprite": "tree", "properties": [{"name": "to", "type": "map"}]}"#.utf8))
    #expect(object.parts == nil && object.properties?.first?.list == nil && object.properties?.first?.type == .map)
    let written = ObjectFile(properties: [.init(name: "path", type: .point, value: "1,2\n3,4", list: true)], parts: [.init(sprite: "crown", y: -16, above: true)])
    #expect(try JSONDecoder().decode(ObjectFile.self, from: JSONEncoder().encode(written)) == written)
    let tiles = SheetFile(frameWidth: 8, frameHeight: 8, properties: [.init(name: "water", type: .toggle)], tiles: [3: ["water": "true"]])
    #expect(try String(decoding: JSONEncoder().encode(tiles), as: UTF8.self).contains(#""tiles":{"3":{"water":"true"}}"#))
    #expect(try JSONDecoder().decode(SheetFile.self, from: JSONEncoder().encode(tiles)) == tiles)
}

final class Lantern: Entity, Placeable {
    override init() {
        super.init()
        var own = Sprite("own")
        (own.glows, own.shader, own.opacity, own.color) = (true, Shader("shimmer", [0.5]), 0.8, 0xFFCC88)
        sprite = own
    }
}

@MainActor @Test func objectsAreMadeWithoutBeingAddedAndKeepTheLooksTheirClassGivesTheirSprite() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "looks-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets.appending(path: "Objects"), withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try ObjectFile(sprite: "lantern", class: "Lantern").write(to: assets.appending(path: "Objects/lantern.object"))
    try ObjectFile(sprite: "bat", class: "Bat").write(to: assets.appending(path: "Objects/bat.object"))
    let module = Scene.module
    Scene.module = "SpellcrestTests"
    defer { Scene.module = module }
    let scene = Scene()
    // Made, not added: what it would be before it's there, like the building a kit puts down.
    let ghost = scene.make(ObjectName("bat"), at: [8, 8])
    #expect(ghost is Bat && ghost.sprite?.image == "bat" && ghost.position == [8, 8] && ghost.scene == nil && scene.entities.isEmpty)
    // The object's sprite takes the place of its class's, keeping what the object editor has no field for.
    let lantern = scene.add(ObjectName("lantern"), at: .zero)
    #expect(lantern.sprite?.image == "lantern" && lantern.sprite?.glows == true && lantern.sprite?.shader == Shader("shimmer", [0.5]))
    #expect(lantern.sprite?.opacity == 0.8 && lantern.sprite?.color == 0xFFCC88)
}

@MainActor @Test func aGamesOwnFilesAreFoundByNameAndAMissingImageMapOrSoundGoesOnWithoutIt() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "own-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets.appending(path: "Data"), withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try "stone\nreed".write(to: assets.appending(path: "Data/words.txt"), atomically: true, encoding: .utf8)
    #expect(Assets.url("words.txt")?.lastPathComponent == "words.txt" && Assets.url("none.txt") == nil)
    // Missing, an image draws nothing, a map is empty and a sound is silent, each said once, and the game goes on.
    let screen = try canvas(Size(2, 2))
    #expect(colors(try render(screen) { screen.draw("ghost", x: 0, y: 0) }, width: 2) == ["..", ".."] && screen.missing.contains("ghost"))
    let map = Tilemap("nowhere")
    #expect(map.layers.isEmpty && map.size == Size(0, 0) && !map.isSolid(Rect(x: 0, y: 0, width: 8, height: 8)))
    Sound.play("silence")
    #expect(said.withLock { $0.contains("nowhere.tilemap") && $0.contains("silence sound") })
}
