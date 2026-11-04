import CoreGraphics
import Foundation
import ImageIO
import Metal
import SpellcrestProtocol
import Testing
@testable import Spellcrest

/// A kit of two-pixel parts: a body in skin and brown boots, a robe in cloth and a hat in cloth and hair.
private let kit = KitFile(frameWidth: 2, frameHeight: 1, animations: ["stand": .init(frames: [0], fps: 2)],
                          slots: [.init(name: "body"), .init(name: "robe", materials: ["cloth"]), .init(name: "hat", materials: ["cloth", "hair"])],
                          materials: [.init(name: "cloth", ramps: [.init(name: "blue", colors: ["#000010", "#000020"]),
                                                                   .init(name: "red", colors: ["#100000", "#200000"])]),
                                      .init(name: "hair", ramps: [.init(name: "brown", colors: ["#301000"]), .init(name: "purple", colors: ["#300030"])])])
private let parts: [String: [UInt32]] = [
    "body/plain": [0xF0C0A0FF, 0x301000FF], // skin, and a boot in the hair's brown
    "robe/long": [0x000020FF, 0], // the lit blue, and clear
    "hat/witch": [0x00001080, 0x301000FF], // the dark blue half see-through, and hair
    "hat/wide": [0x000010FF, 0x000010FF, 0x000010FF],
]

private func compose(_ person: PersonFile) throws -> [UInt32] {
    try person.compose(kit) { path in (parts[path]!, parts[path]!.count) }.pixels // a row each
}

@Test func aPersonStacksItsPartsBackToFrontInTheShadesItWears() throws {
    #expect(try compose(PersonFile(parts: ["body": "plain", "robe": "long"])) == [0x000020FF, 0x301000FF]) // as drawn
    #expect(try compose(PersonFile(parts: ["body": "plain", "robe": "long"], wears: ["cloth": "red"])) == [0x200000FF, 0x301000FF])
    // The hat wears hair, the body doesn't, so its boot keeps its brown; half the hat's red shows over the robe's.
    let witch = try compose(PersonFile(parts: ["robe": "long", "body": "plain", "hat": "witch"], wears: ["cloth": "red", "hair": "purple"]))
    #expect(witch == [0x180000FF, 0x300030FF])
}

@Test func aPersonThatCantBeMadeSaysWhatToChange() {
    func message(_ person: PersonFile) -> String? {
        do {
            _ = try compose(person)
            return nil
        } catch {
            return (error as? PersonError)?.description
        }
    }
    #expect(message(PersonFile(parts: ["body": "plain"], wears: ["cloth": "green"])) == "the kit's cloth has no ramp called green, only blue, red")
    #expect(message(PersonFile(parts: ["cape": "short"])) == "the kit has no slot called cape")
    #expect(message(PersonFile(parts: ["body": "plain"], wears: ["skin": "tan"])) == "the kit has no material called skin")
    #expect(message(PersonFile(parts: [:])) == "a person wears a part in one slot at least")
    #expect(message(PersonFile(parts: ["body": "plain", "hat": "wide"])) == "hat/wide is 3 pixels wide and a person 2: a part has every frame, laid out as theirs")
}

@Test func kitsAndPeopleReadAsTheyWereWritten() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "people-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try kit.write(to: folder.appending(path: "kit.json"))
    #expect(try KitFile(contentsOf: folder.appending(path: "kit.json")) == kit)
    let witch = PersonFile(parts: ["body": "plain", "hat": "witch"], wears: ["cloth": "red"])
    try witch.write(to: folder.appending(path: "witch.person"))
    #expect(try PersonFile(contentsOf: folder.appending(path: "witch.person")) == witch)
    #expect(kit.sheet == SheetFile(frameWidth: 2, frameHeight: 1, animations: ["stand": .init(frames: [0], fps: 2)]))
}

@Test func aPartDrawnOnceFollowsItsAnchorAndLeavesTheBodyInFrontOfIt() throws {
    // Four frames of two pixels: a body, and a cap drawn once that follows the head, which moves a pixel right in
    // frame 2 and is gone in frame 3; in frame 1 an arm is in front of the head's second pixel.
    let kit = KitFile(frameWidth: 2, frameHeight: 1, frames: 4, columns: 4, slots: [.init(name: "body"), .init(name: "hat", follows: "head")],
                      materials: [], anchors: ["head": [.init(0, 0), .init(0, 0), .init(1, 0), nil]], front: "front")
    let (b, c): (UInt32, UInt32) = (0x8040_20FF, 0x2040_A0FF)
    let images: [String: [UInt32]] = ["body/plain": [b, b, b, b, b, b, b, b], "hat/cap": [c, c], "hat/big": [c, c, c], "front": [0, 0, 0, 0xFF, 0, 0, 0, 0]]
    func person(_ parts: [String: String]) throws -> (pixels: [UInt32], width: Int) {
        try PersonFile(parts: parts).compose(kit) { path in (images[path]!, path == "hat/big" ? 3 : path == "hat/cap" ? 2 : 8) }
    }
    #expect(try person(["body": "plain", "hat": "cap"]) == ([c, c, c, b, b, c, b, b], 8))
    #expect(try person(["hat": "cap"]) == ([c, c, c, 0, 0, c, 0, 0], 8)) // laid out as the kit says, with no part of every frame
    #expect(throws: PersonError("hat/big is 3 pixels wide and a person 8: a part has every frame, laid out as theirs, or a frame or a few in a row to follow the head")) {
        try person(["body": "plain", "hat": "big"])
    }
    let file = FileManager.default.temporaryDirectory.appending(path: "kit-\(UUID()).json")
    try kit.write(to: file)
    #expect(try KitFile(contentsOf: file) == kit && String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(#""head":[[0,0],[0,0],[1,0],null]"#))
}

@Test func aWeaponShowsTheFrameEachOfThePersonsFramesSaysAndActionsFollowWhatTheyHold() throws {
    // Three frames of two pixels: a sword drawn once in two frames, upright and level, held in the first and the third,
    // level in the third. A slash is the sword's attack; with nothing in hand it's a spell.
    let kit = KitFile(frameWidth: 2, frameHeight: 1, frames: 3, columns: 3,
                      animations: ["stand": .init(frames: [0], fps: 2), "slash": .init(frames: [0, 2], fps: 8), "spell": .init(frames: [1], fps: 4)],
                      slots: [.init(name: "weapon", follows: "grip")], materials: [],
                      anchors: ["grip": [.init(0, 0), nil, .init(0, 0, frame: 1)]],
                      actions: ["attack": .init(slot: "weapon", animations: ["sword": "slash", "": "spell"])])
    let (u, l): (UInt32, UInt32) = (0xC0C0_C0FF, 0x8080_80FF)
    let sword = try PersonFile(parts: ["weapon": "sword"]).compose(kit) { _ in ([u, 0, l, 0], 4) }
    #expect(sword == ([u, 0, 0, 0, l, 0], 6))
    #expect(PersonFile(parts: ["weapon": "sword"]).sheet(kit).animations?["attack"] == .init(frames: [0, 2], fps: 8))
    #expect(PersonFile(parts: [:]).sheet(kit).animations?["attack"] == .init(frames: [1], fps: 4)) // empty hands
    #expect(PersonFile(parts: ["weapon": "bow"]).sheet(kit).animations?["attack"] == nil) // none for it, nor any other
    let file = FileManager.default.temporaryDirectory.appending(path: "kit-\(UUID()).json")
    try kit.write(to: file)
    #expect(try KitFile(contentsOf: file) == kit && String(decoding: try Data(contentsOf: file), as: UTF8.self).contains(#""grip":[[0,0],null,[0,0,1]]"#))
}

/// A game whose kit has two frames of a pixel: a body, and hats drawn once that follow the head, in cloth.
private func makeGame() throws -> URL {
    let game = FileManager.default.temporaryDirectory.appending(path: "people-\(UUID())")
    for folder in ["Assets/Parts/body", "Assets/Parts/hat", "Assets/People"] {
        try FileManager.default.createDirectory(at: game.appending(path: folder), withIntermediateDirectories: true)
    }
    try KitFile(frameWidth: 1, frameHeight: 1, frames: 2, columns: 2, animations: ["stand": .init(frames: [0, 1], fps: 2)],
                slots: [.init(name: "body"), .init(name: "hat", materials: ["cloth"], follows: "head")],
                materials: [.init(name: "cloth", ramps: [.init(name: "blue", colors: ["#2040A0"]), .init(name: "red", colors: ["#A02020"])])],
                anchors: ["head": [.init(0, 0), nil]])
        .write(to: game.appending(path: "Assets/Parts/kit.json"))
    try png([0xFFCC_99FF, 0xFFCC_99FF], width: 2).write(to: game.appending(path: "Assets/Parts/body/plain.png"))
    try png([0x2040_A0FF], width: 1).write(to: game.appending(path: "Assets/Parts/hat/cap.png"))
    try PersonFile(parts: ["body": "plain", "hat": "cap"], wears: ["cloth": "red"]).write(to: game.appending(path: "Assets/People/ann.person"))
    FileManager.default.changeCurrentDirectoryPath(game.path) // games load Assets/ relative to here
    return game
}

/// 0xRRGGBBAA pixels as a PNG, one row.
private func png(_ pixels: [UInt32], width: Int) -> Data {
    let bytes = pixels.map(\.bigEndian).withUnsafeBytes { Data($0) }
    let image = CGImage(width: width, height: pixels.count / width, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// A texture's pixels as 0xRRGGBBAA.
private func pixels(_ texture: GPUTexture) -> [UInt32] {
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    metal(texture).getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return (0..<texture.width * texture.height).map { i in
        let p = bytes[i * 4..<i * 4 + 4].map(UInt32.init)
        return texture.format == .bgra8 ? p[2] << 24 | p[1] << 16 | p[0] << 8 | p[3] : p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]
    }
}

@MainActor @Test func aPersonIsMadeInPlayAndAgainWhenTheirGearOrAPartChanges() throws {
    let game = try makeGame()
    let screen = Screen(size: Size(8, 8), gpu: try #require(systemGPU()), format: .bgra8)
    var ann = Person("ann")
    #expect(ann.parts == ["body": "plain", "hat": "cap"] && ann.wears == ["cloth": "red"])
    var sprite = Sprite(ann)
    #expect(pixels(screen.texture(sprite.image)) == [0xA020_20FF, 0xFFCC_99FF]) // the red cap on her head in the first frame
    #expect(screen.sheet(sprite.image)?.animations?["stand"]?.frames == [0, 1] && frameSize(sprite.image) == Size(1, 1))

    sprite.play("stand")
    ann.parts["hat"] = nil // taken off in play
    sprite.wear(ann)
    #expect(sprite.animation == "stand" && pixels(screen.texture(sprite.image)) == [0xFFCC_99FF, 0xFFCC_99FF])
    #expect(Person(parts: ["body": "plain", "hat": "cap"], wears: ["cloth": "red"]).image == Sprite(Person("ann")).image.asImageName) // the same look, the same image

    ann.parts["hat"] = "cap" // and on again; then the cap is drawn anew in the editor
    sprite.wear(ann)
    _ = screen.texture(sprite.image)
    try png([0x40A0_40FF], width: 1).write(to: game.appending(path: "Assets/Parts/hat/cap.png"))
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: game.appending(path: "Assets/Parts/hat/cap.png").path)
    screen.reloadChangedAssets()
    #expect(pixels(screen.texture(sprite.image)) == [0x40A0_40FF, 0xFFCC_99FF]) // drawn in green, worn as drawn: no blue to swap
}

@MainActor @Test func aPersonWhoCantBeMadeDrawsNothingAndSaysWhy() throws {
    _ = try makeGame()
    let screen = Screen(size: Size(8, 8), gpu: try #require(systemGPU()), format: .bgra8)
    let nobody = Sprite(Person(parts: ["body": "plain", "cape": "long"]))
    #expect(screen.texture(nobody.image).width == screen.clear.width && screen.sheet(nobody.image) == nil)
    #expect(Person("nobody") == Person()) // no such file
}

private extension String {
    var asImageName: ImageName { ImageName(self) }
}

@Test func aHatKeepsHairInsideItButInAHoleItClosesRound() throws {
    // Frames of 3 by 3: hair everywhere; a cap over the top two pixels of the middle column and the top of the left; a
    // hood all round but the middle.
    let kit = KitFile(frameWidth: 3, frameHeight: 3, slots: [.init(name: "hair"), .init(name: "hat", hides: ["hair"])], materials: [])
    let (h, c): (UInt32, UInt32) = (0x6040_20FF, 0x2040_A0FF)
    let images: [String: [UInt32]] = ["hair/all": .init(repeating: h, count: 9), "hat/cap": [c, c, 0, 0, c, 0, 0, 0, 0], "hat/hood": [c, c, c, c, 0, c, c, c, c]]
    func person(_ hat: String) throws -> [UInt32] { try PersonFile(parts: ["hair": "all", "hat": hat]).compose(kit) { (images[$0]!, 3) }.pixels }
    #expect(try person("cap") == [c, c, 0, h, c, 0, h, h, h]) // below the cap's lowest pixel in each column, and beside it its edge's
    #expect(try person("hood") == [c, c, c, c, h, c, c, c, c]) // in the hood's opening
}

@Test func aHelmetKeepsAllTheHairInsideButInItsOpening() throws {
    // Frames of 5 by 4: hair everywhere; a helmet, a dome over the top with a guard down each side, the left one longer,
    // and a cap drawn the same that doesn't wrap the head.
    let kit = KitFile(frameWidth: 5, frameHeight: 4, slots: [.init(name: "hair"), .init(name: "hat", hides: ["hair"], wraps: ["helmet"])], materials: [])
    let (h, c): (UInt32, UInt32) = (0x6040_20FF, 0x8090_A0FF)
    let helmet: [UInt32] = [c, c, c, c, c, c, 0, 0, 0, c, c, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    let images: [String: [UInt32]] = ["hair/all": .init(repeating: h, count: 20), "hat/helmet": helmet, "hat/cap": helmet]
    func person(_ hat: String) throws -> [UInt32] { try PersonFile(parts: ["hair": "all", "hat": hat]).compose(kit) { (images[$0]!, 5) }.pixels }
    #expect(try person("helmet") == [c, c, c, c, c, c, h, h, h, c, c, 0, 0, 0, 0, 0, 0, 0, 0, 0]) // between its guards, under its dome
    #expect(try person("cap") == [c, c, c, c, c, c, h, h, h, c, c, h, h, h, h, h, h, h, h, h]) // below its edge
}

@Test func aSlotCanWearItsOwnRampOfAMaterial() throws {
    // Frames of one pixel: a hat over a robe, both in cloth, drawn blue; the person wears red cloth and a black hat.
    let kit = KitFile(frameWidth: 1, frameHeight: 1, slots: [.init(name: "robe", materials: ["cloth"]), .init(name: "hat", materials: ["cloth"])],
                      materials: [.init(name: "cloth", ramps: [.init(name: "blue", colors: ["#2040A0"]), .init(name: "red", colors: ["#A02020"]),
                                                               .init(name: "black", colors: ["#202020"])])])
    let images: [String: [UInt32]] = ["robe/long": [0x2040_A0FF, 0x2040_A0FF], "hat/cap": [0x2040_A0FF, 0]]
    func person(_ wears: [String: String]) throws -> [UInt32] {
        try PersonFile(parts: ["robe": "long", "hat": "cap"], wears: wears).compose(kit) { (images[$0]!, 2) }.pixels
    }
    #expect(try person(["cloth": "red", "hat.cloth": "black"]) == [0x2020_20FF, 0xA020_20FF]) // the hat its own, the robe the cloth's
    #expect(try person(["hat.cloth": "black"]) == [0x2020_20FF, 0x2040_A0FF]) // the robe as drawn
    #expect(throws: PersonError.self) { try person(["cap.cloth": "black"]) } // no such slot
}
