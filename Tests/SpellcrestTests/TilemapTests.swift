import Foundation
import ImageIO
import Metal
import SpellcrestProtocol
import Testing
@testable import Spellcrest

@MainActor @Test func tilemapFilesLoadWithSolidTilesFromTheTilesetMarkersAndObjects() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "tilemap-\(UUID())")
    try FileManager.default.createDirectory(at: folder.appending(path: "Assets"), withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(folder.path) // games load Assets/ relative to here
    try SheetFile(frameWidth: 8, frameHeight: 8, solid: [0]).write(to: folder.appending(path: "Assets/tiles.json"))
    try TilemapFile(tileset: "tiles", width: 3, height: 2, layers: [
        .init(name: "Ground", tiles: [-1, -1, -1, 0, 1, 0]),
        .init(name: "Things", tiles: [5, -1, 5, -1, -1, -1]),
        .init(name: "Roof", tiles: [-1, -1, -1, -1, -1, -1], above: true),
    ], objects: [
        .init(name: "coin", x: 3, y: 4), .init(name: "door", x: 16, y: 0, properties: ["to": "level2"], width: 16, height: 4),
        .init(name: "coin", x: 20, y: 9), .init(name: "tree", x: 0, y: 0), .init(name: "rock", x: 0, y: 0),
    ]).write(to: folder.appending(path: "Assets/level.tilemap"))
    try png(width: 12, height: 20, to: folder.appending(path: "Assets/tree.png")) // objects without a size are as big as their image
    try png(width: 32, height: 8, to: folder.appending(path: "Assets/rock.png")) // or its frames
    try SheetFile(frameWidth: 16, frameHeight: 8).write(to: folder.appending(path: "Assets/rock.json"))

    var map = Tilemap("level")
    #expect(map.size == Size(24, 16) && map.above == [2])
    #expect(map.isSolid(Rect(x: 0, y: 8, width: 8, height: 8)))  // tile 0 is solid
    #expect(!map.isSolid(Rect(x: 8, y: 8, width: 8, height: 8))) // tile 1 isn't
    #expect(map.removeTiles(5) == [[0, 0], [16, 0]])
    #expect(map.layers[1].allSatisfy { $0 == nil })
    #expect(map.objects(named: "coin") == [[3, 4], [20, 9]])
    #expect(map.objects.first { $0.name == "door" }?.properties == ["to": "level2"])
    #expect(map.objects.map(\.box) == [Rect(x: 3, y: 4, width: 8, height: 8), Rect(x: 16, y: 0, width: 16, height: 4), Rect(x: 20, y: 9, width: 8, height: 8),
                                        Rect(x: 0, y: 0, width: 12, height: 20), Rect(x: 0, y: 0, width: 16, height: 8)])
}

/// A clear PNG of that size.
func png(width: Int, height: Int, to file: URL) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Test func tilemapFilesFromBeforeObjectsStayTheSame() throws {
    let old = #"{"height":1,"layers":[{"name":"Ground","tiles":[-1]}],"tileset":"tiles","width":1}"#
    let file = FileManager.default.temporaryDirectory.appending(path: "old-\(UUID()).tilemap")
    try Data(old.utf8).write(to: file)
    var map = try TilemapFile(contentsOf: file)
    #expect(map.objects == nil)
    try map.write(to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == old)

    map.objects = [.init(name: "coin", x: 1, y: 2, properties: ["value": "5"]), .init(name: "start", x: 0, y: 0)]
    try map.write(to: file)
    #expect(try TilemapFile(contentsOf: file) == map)

    map.objects?.append(.init(name: "door", x: 16, y: 32, properties: ["to": "house"], width: 16, height: 8)) // a zone
    map.layers.append(.init(name: "Roof", tiles: [-1], above: true))
    try map.write(to: file)
    #expect(try TilemapFile(contentsOf: file) == map)
}

@MainActor @Test func tilemapsReloadWhenTheirFilesChangeKeepingRemovedTilesOut() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "reload-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    func save(_ file: some AssetFile, as name: String, secondsLater: Double) throws {
        try file.write(to: assets.appending(path: name))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: secondsLater)], ofItemAtPath: assets.appending(path: name).path)
    }
    try save(SheetFile(frameWidth: 8, frameHeight: 8), as: "tiles.json", secondsLater: 0)
    try save(TilemapFile(tileset: "tiles", width: 2, height: 1, layers: [.init(name: "Ground", tiles: [5, -1])]), as: "level.tilemap", secondsLater: 0)
    var map = Tilemap("level")
    _ = map.removeTiles(5) // a marker, like where a coin goes

    try save(TilemapFile(tileset: "tiles", width: 2, height: 1, layers: [.init(name: "Ground", tiles: [5, 1])]), as: "level.tilemap", secondsLater: 10)
    map.reloadIfChanged()
    #expect(map.layers == [[nil, 1]]) // the new tile is in, and the marker stays out
    try save(SheetFile(frameWidth: 8, frameHeight: 8, solid: [1]), as: "tiles.json", secondsLater: 20)
    map.reloadIfChanged()
    #expect(map.solid == [1])
    try Data("{".utf8).write(to: assets.appending(path: "level.tilemap")) // can't be read: the map stays
    map.reloadIfChanged()
    #expect(map.layers == [[nil, 1]])
}

@MainActor @Test func tilesAreReadAndChangedByPixelAndStayChangedThroughAReload() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "tiles-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try SheetFile(frameWidth: 8, frameHeight: 8).write(to: assets.appending(path: "tiles.json"))
    let file = assets.appending(path: "level.tilemap")
    try TilemapFile(tileset: "tiles", width: 3, height: 2, layers: [.init(name: "Ground", tiles: [0, 1, 2, 3, 4, 5])]).write(to: file)
    var map = Tilemap("level")
    #expect(map.tile(at: [8, 0], layer: 0) == 1 && map.tile(at: [23.9, 15.9], layer: 0) == 5)
    #expect(map.tile(at: [-0.5, 0], layer: 0) == nil && map.tile(at: [24, 0], layer: 0) == nil && map.tile(at: [0, 0], layer: 1) == nil)
    map.setTile(9, at: [9, 9], layer: 0) // a bush cut, say
    map.setTile(nil, at: [0, 0], layer: 0)
    map.setTile(7, at: [-1, 0], layer: 0) // outside: nothing
    #expect(map.layers == [[nil, 1, 2, 3, 9, 5]] && map.tile(at: [0, 0], layer: 0) == nil)

    try TilemapFile(tileset: "tiles", width: 3, height: 2, layers: [.init(name: "Ground", tiles: [6, 6, 6, 6, 6, 6])]).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: file.path)
    map.reloadIfChanged() // painted in the editor while the game runs
    #expect(map.layers == [[nil, 6, 6, 6, 9, 6]])
}

@Test func animatedTilesShowTheFrameForTheMapsTime() {
    var map = Tilemap("tiles", tileSize: 8, rows: ["~"], legend: ["~": 12])
    let animations: [String: SheetFile.Animation] = ["12": .init(frames: [12, 13, 14], fps: 4), "walk": .init(frames: [0, 1], fps: 8), "3": .init(frames: [], fps: 4)]
    #expect(map.frames(animations) == [12: 12])
    map.time = 0.5 // two frames on
    #expect(map.frames(animations) == [12: 14])
    map.time = 0.75 // and round again
    #expect(map.frames(animations) == [12: 12])
}

@MainActor @Test func mapsQueueOnlyTheTilesInView() throws {
    let screen = Screen(size: Size(16, 16), gpu: try #require(systemGPU()), format: .bgra8)
    screen.textures["tiles"] = screen.builtInFont // any image does as a tileset
    let map = Tilemap("tiles", tileSize: 8, rows: Array(repeating: "#####", count: 3), legend: ["#": 0]) // 5x3 tiles on a 2x2-tile canvas
    func tiles(at camera: Vector) -> Int {
        (screen.offset, screen.vertices) = (camera, [])
        screen.draw(map)
        return screen.vertices.count / 30 // six corners, five values each
    }
    #expect(tiles(at: [0, 0]) == 4)
    #expect(tiles(at: [12, 4]) == 9) // between tiles: 3 columns and 3 rows show a part
    #expect(screen.vertices[0][0] == -4 && screen.vertices[0][1] == -4) // the first, column 1 and row 0, half off the canvas
    #expect(tiles(at: [0.5, 0]) == 6) // between pixels: a third column shows its first pixel
    #expect(tiles(at: [-4, -4]) == 4 && tiles(at: [36, 20]) == 1) // past the top-left and bottom-right corners
    #expect(tiles(at: [100, 0]) == 0)
}

@MainActor @Test func aMapMadeInCodeHasItsTilesetsPropertiesAndAFilesLayersHaveTheirNames() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "coded-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try SheetFile(frameWidth: 8, frameHeight: 8, opaque: [1], properties: [.init(name: "water", type: .toggle)], tiles: [1: ["water": "true"]])
        .write(to: assets.appending(path: "tiles.json"))
    let coded = Tilemap("tiles", tileSize: 8, rows: [".#"], legend: ["#": 1])
    #expect(coded.properties(at: [8, 0], layer: 0).bool("water") && !coded.properties(at: [0, 0], layer: 0).bool("water"))
    #expect(coded.opaque == [1] && coded.solid == [1] && coded.layer(named: "Ground") == nil)
    try TilemapFile(tileset: "tiles", width: 1, height: 1, layers: [.init(name: "Ground", tiles: [0]), .init(name: "Paths", tiles: [-1])])
        .write(to: assets.appending(path: "level.tilemap"))
    #expect(Tilemap("level").layer(named: "Paths") == 1 && Tilemap("level").layer(named: "Ground") == 0 && Tilemap("level").layer(named: "Roof") == nil)
}

@MainActor @Test func aMissingMapIsEmptyAndLoadsOnceItsFileIsThere() throws {
    let assets = FileManager.default.temporaryDirectory.appending(path: "later-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    var map = Tilemap("cave")
    #expect(map.layers.isEmpty && map.tileset.isEmpty)
    try SheetFile(frameWidth: 8, frameHeight: 8).write(to: assets.appending(path: "rock.json"))
    try TilemapFile(tileset: "rock", width: 2, height: 1, layers: [.init(name: "Ground", tiles: [0, 1])]).write(to: assets.appending(path: "cave.tilemap"))
    map.reloadIfChanged()
    #expect(map.layers == [[0, 1]] && map.tileset == "rock")
}
