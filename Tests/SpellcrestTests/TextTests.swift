import ImageIO
import Metal
import SpellcrestProtocol
import Testing
@testable import Spellcrest

@Test func textIsSpacedByEachGlyphsWidthWithDigitsAllAsWide() {
    // A, B and ? fill 3 of their 4 columns, "." only its second, and the digit 1 its second while 2 fills 3.
    let font = Font(glyph: Size(4, 6), characters: "AB?.12", columns: [0...2, 0...2, 0...2, 1...1, 1...1, 0...2])
    // "b" draws as B, "!" isn't in the font so "?" stands in, and the space takes up half a frame but draws nothing.
    #expect(font.layout("Ab\n! A").map { [$0.index, $0.x, $0.y] } == [[0, 0, 0], [1, 4, 0], [2, 0, 6], [0, 6, 6]])
    #expect(font.size(of: "Ab\n! A") == Size(9, 12)) // to the last line's last pixel, not the space after it
    // "." takes up 1 column and its space, its frame starting a column left so its pixel lands right after A's space.
    #expect(font.layout("A.B").map(\.x) == [0, 3, 6])
    #expect(font.layout("A.BA").last?.x == font.size(of: "A.B").width + 1) // the size ends a space before the next glyph
    // Digits take up the widest one's 3 columns, so "1" is centered in them, and "12" is as wide as "22".
    #expect(font.layout("12").map(\.x) == [0, 4] && font.size(of: "12") == font.size(of: "22"))
    #expect(Font(glyph: Size(4, 6), characters: "AB", columns: [0...2, 0...2]).layout("!").isEmpty) // no "?" either: nothing
    #expect(Font.builtIn.index(of: "a") == Font.builtIn.index(of: "A") && Font.builtIn.index(of: "é") == Font.builtIn.index(of: "?"))
}

@Test func textWrapsAtSpacesAndBreaksWordsWiderThanTheWidth() {
    let font = Font.builtIn // letters advance 4 pixels, the space 2
    #expect(font.lines("AB CD EF", width: 17) == ["AB CD", "EF"]) // "AB CD" is 17 wide, from A's first pixel to D's last
    #expect(font.lines("AB CD EF", width: 16) == ["AB", "CD", "EF"])
    #expect(font.lines("ABCDEFGH I", width: 14) == ["ABC", "DEF", "GH I"]) // too wide for a line: broken where it stops fitting
    #expect(font.lines("AB\n\nCD EF", width: 100) == ["AB", "", "CD EF"] && font.lines("A", width: 1) == ["A"])
    #expect(font.size(of: "AB CD EF", width: 18) == Size(17, 12) && font.size(of: "AB CD EF") == Size(27, 6))
    #expect(font.layout("AB CD EF", width: 18).last.map { [$0.x, $0.y] } == [4, 6]) // F, second on the second line
}

@MainActor @Test func glyphsAreMeasuredInTheBuiltInArtAndInFontImagesAgainWhenTheyChange() throws {
    let builtIn = Font.builtIn
    #expect(builtIn.columns[builtIn.index(of: ".")!] == 1...1 && builtIn.columns[builtIn.index(of: "A")!] == 0...2)
    #expect(builtIn.columns[0] == nil && builtIn.digits == 3) // the space
    #expect(builtIn.size(of: "COINS 3/10").width == 37) // letters and digits as before, the space 2 narrower, none after the 0

    let assets = FileManager.default.temporaryDirectory.appending(path: "font-\(UUID())/Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(assets.deletingLastPathComponent().path) // games load Assets/ relative to here
    try SheetFile(frameWidth: 4, frameHeight: 6, characters: "AB.C").write(to: assets.appending(path: "tiny.json"))
    // Two rows of two 4x6 frames: A, an empty B, then "." and C below.
    func save(_ rows: [String], secondsLater: Double) throws {
        let context = try #require(CGContext(data: nil, width: 8, height: 12, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try #require(context.data?.assumingMemoryBound(to: UInt32.self))
        for (y, row) in rows.enumerated() { for (x, pixel) in row.enumerated() where pixel == "#" { pixels[y * 8 + x] = 0xFFFF_FFFF } }
        let file = assets.appending(path: "tiny.png")
        let png = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(png, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(png))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: secondsLater)], ofItemAtPath: file.path)
    }
    let a = ["###.....", "#.#.....", "###.....", "#.#.....", "#.#.....", "........"]
    try save(a + [".#......", "......##"], secondsLater: 0)
    let screen = Screen(size: Size(8, 8), gpu: try #require(systemGPU()), format: .bgra8)
    #expect(screen.font("tiny").1.columns == [0...2, nil, 1...1, 2...3])
    try save(a.map { $0.prefix(7) + "#" } + [".#......", "......##"], secondsLater: 10) // a B of one column, at the right
    screen.reloadChangedAssets()
    #expect(screen.font("tiny").1.columns == [0...2, 3...3, 1...1, 2...3])
}

@MainActor @Test func textAndSpritesDrawTinted() throws {
    let screen = try canvas(Size(8, 7))
    screen.textures["dot"] = try texture([UInt32](repeating: 0xFFFF_FFFF, count: 4), width: 2) // a 2x2 sprite, one frame since there's no dot.json
    let commands = try #require(screen.gpu.commands())
    screen.begin(commands, Targets([Target(texture: screen.canvas, load: .clear(red: 0, green: 0, blue: 0, alpha: 1))])) // to black
    screen.text("A", x: 1, y: 1, color: 0xFF0000)
    var sprite = Sprite("dot")
    sprite.color = 0x00FF00
    screen.draw(sprite, x: 5, y: 1)
    screen.end()
    let pixels = try #require(screen.gpu.buffer(length: 8 * 7 * 4))
    commands.copy(screen.canvas, to: pixels)
    commands.commit()
    commands.waitUntilCompleted()
    let bgra = pixels.contents.bindMemory(to: UInt32.self)
    let colors = (0..<7).map { y in String((0..<8).map { [0xFFFF_0000: "#", 0xFF00_FF00: "o"][bgra[y * 8 + $0]] ?? "." }) }
    #expect(colors == ["........", "..#..oo.", ".#.#.oo.", ".###....", ".#.#....", ".#.#....", "........"])
}

@MainActor @Test func textDrawsScaledFadedAndAlignedAndImagesDrawScaledAndSayTheirSize() throws {
    let screen = try canvas(Size(12, 16))
    let pixels = try render(screen) {
        screen.text("A", x: 6, y: 0, color: 0xFF0000, scale: 2, align: .center) // around x 6, each pixel 2 square
        screen.text("A", x: 0, y: 11, width: 12, color: 0xFF0000, opacity: 0.5, align: .right) // at the right of 12, half faded
    }
    #expect(colors(pixels, width: 12).prefix(10) == [".....rr.....", ".....rr.....", "...rr..rr...", "...rr..rr...", "...rrrrrr...",
                                                       "...rrrrrr...", "...rr..rr...", "...rr..rr...", "...rr..rr...", "...rr..rr..."])
    let faded = pixels[11 * 12 + 10] // the top of the second A, in the last three columns
    #expect((127...128).contains(faded >> 16 & 0xFF) && faded & 0xFFFF == 0 && pixels[11 * 12 + 9] == 0xFF00_0000)
    #expect(screen.textSize("A", scale: 2) == Size(6, 12) && screen.textSize("A A") == Size(9, 6))

    // Typed out a letter at a time, a word too wide for the box breaks with a "\n" of its own, so the wrapped text is
    // longer than the words: counting to the words' own count stops short.
    let typed = screen.wrap("ABCDEFGH", width: 14)
    #expect(typed == "ABC\nDEF\nGH" && typed.prefix(8).filter(\.isLetter).count == 6)

    screen.textures["dot"] = try texture([0xFF00_00FF, 0xFF00_00FF, 0xFF00_00FF, 0xFF00_00FF], width: 2) // red, 2x2
    screen.sheets["dot"] = .some(nil)
    #expect(screen.size(of: "dot") == Size(2, 2) && screen.size(of: ImageName("nowhere")) == nil)
    let small = try canvas(Size(4, 4))
    small.textures["dot"] = screen.textures["dot"]
    small.sheets["dot"] = .some(nil)
    #expect(colors(try render(small) { small.draw("dot", x: 0, y: 0, scale: 2) }, width: 4) == ["rrrr", "rrrr", "rrrr", "rrrr"])
}
