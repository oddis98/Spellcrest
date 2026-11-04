import Foundation

public extension Screen {
    /// Draws `text` with its top-left corner at (x, y); `\n` starts a new line. Given a `width` in pixels, it wraps: a
    /// word that would go past it starts a new line, and a word wider than that breaks. `font` is an image cut into
    /// glyphs, `Assets/<font>.png`, whose `.json` lists the `characters` they show (draw one in the pixel editor), like
    /// `font: .font` for `Assets/Sprites/font.png`; without it, a built-in 3x5 font draws. Each glyph takes up the
    /// columns it has pixels in, then 1 pixel of space, and digits all take up the widest one's, so numbers don't shift
    /// as they count. `color` (0xRRGGBB) tints the glyphs, and white leaves them as they are; `opacity`, from 0 to 1,
    /// fades them; and each of their pixels is `scale` pixels square, `width` counting those. `align` puts each line at
    /// the left, the middle or the right of `width`, or without one, of `x`:
    /// `screen.text(title, x: 160, y: 40, scale: 3, align: .center)`. Where the canvas is drawn bigger than the game, as
    /// it is on most screens, x and y go to the nearest part of a pixel below them, so what moves between pixels moves
    /// smoothly; give whole numbers to keep text on the game's pixels.
    @_disfavoredOverload func text(_ text: String, x: Double, y: Double, width: Int? = nil, font: String? = nil, color: UInt32 = 0xFFFFFF,
                                   opacity: Double = 1, scale: Int = 1, align: Align = .left) {
        let (texture, font) = self.font(font)
        let scale = max(scale, 1)
        for glyph in font.layout(text, width: width.map { $0 / scale }, align: align) {
            let back = width == nil ? Int(Double(glyph.line * scale) * align.share) : 0 // around or up to x
            quad(texture, x: x + Double(glyph.x * scale - back), y: y + Double(glyph.y * scale), source: region(glyph.index, font.glyph, in: texture),
                 size: Size(font.glyph.width * scale, font.glyph.height * scale), color: color, opacity: opacity)
        }
    }

    /// Draws `text` in one of the game's fonts. (Only the other one leaves `font` out, or calls that leave it out would
    /// match both.)
    func text(_ text: String, x: Double, y: Double, width: Int? = nil, font: ImageName, color: UInt32 = 0xFFFFFF, opacity: Double = 1,
              scale: Int = 1, align: Align = .left) {
        self.text(text, x: x, y: y, width: width, font: font.name, color: color, opacity: opacity, scale: scale, align: align)
    }

    /// The size of `text` in pixels, from its first glyph's first pixel to its last's, wrapped to `width` if you give
    /// one and at `scale` as `text(_:x:y:width:font:color:opacity:scale:align:)` draws it, for example to center it:
    /// `x: Double(160 - screen.textSize(title).width / 2)`.
    @_disfavoredOverload func textSize(_ text: String, width: Int? = nil, font: String? = nil, scale: Int = 1) -> Size {
        let scale = max(scale, 1), size = self.font(font).1.size(of: text, width: width.map { $0 / scale })
        return Size(size.width * scale, size.height * scale)
    }

    /// The size of `text` in one of the game's fonts.
    func textSize(_ text: String, width: Int? = nil, font: ImageName, scale: Int = 1) -> Size {
        textSize(text, width: width, font: font.name, scale: scale)
    }

    /// `text` with a `\n` wherever `text(_:x:y:width:font:color:opacity:scale:align:)` would wrap it. To type out words a
    /// letter at a time, draw `typed.prefix(letters)` of `let typed = wrap(words, width: 200)`, counting `letters` up to
    /// `typed.count`: a word then doesn't jump to the next line halfway through. (A word wider than the box breaks with
    /// a `\n` of its own, so `typed` can be longer than `words`.)
    @_disfavoredOverload func wrap(_ text: String, width: Int, font: String? = nil, scale: Int = 1) -> String {
        self.font(font).1.lines(text, width: width / max(scale, 1)).joined(separator: "\n")
    }

    /// `text` wrapped in one of the game's fonts.
    func wrap(_ text: String, width: Int, font: ImageName, scale: Int = 1) -> String { wrap(text, width: width, font: font.name, scale: scale) }

    /// Where `text(_:x:y:width:font:color:opacity:scale:align:)` puts each line: at the left of its `width`, in the
    /// middle or at the right, or without one, from `x`, around it or up to it.
    enum Align: Sendable {
        /// Lines start at the left: at `x`.
        case left
        /// Each line in the middle: of `width`, or around `x`.
        case center
        /// Lines end at the right: of `width`, or at `x`.
        case right

        /// How much of a line's width it goes before where it's put: none, half or all of it.
        var share: Double { self == .left ? 0 : self == .center ? 0.5 : 1 }
    }
}

extension Screen {
    /// A font's image and how it's cut into glyphs.
    func font(_ name: String?) -> (GPUTexture, Font) {
        guard let name else { return (builtInFont, .builtIn) }
        let texture = texture(name)
        guard let sheet = sheet(name), let characters = sheet.characters else {
            if warned.insert("\(name) font").inserted { print("Spellcrest: \(name).json has no characters, so the built-in font draws instead") }
            return (builtInFont, .builtIn)
        }
        if let font = fonts[name] { return (texture, font) }
        // Measured in the file, since a texture may not be readable from the CPU (Intel Macs can't share textures).
        guard let image = opaquePixels(assetURL("\(name).png")) else { return (builtInFont, .builtIn) } // half-written: next frame
        let glyph = Size(sheet.frameWidth, sheet.frameHeight)
        let font = Font(glyph: glyph, characters: characters, columns: Font.measure(image.pixels, width: image.width, glyph: glyph))
        fonts[name] = font
        return (texture, font)
    }
}

/// How a font's image is cut up: into frames of one size, which show `characters` in order. A glyph takes up the
/// columns it has pixels in, then 1 pixel of space; one without pixels, like the space, takes up half a frame.
struct Font {
    let glyph: Size
    let characters: [String: Int]
    let columns: [ClosedRange<Int>?] // each frame's columns with pixels in them, from `measure`; nil for none
    let digits: Int // the widest digit's width, which every digit takes up so numbers don't shift as they change

    /// Characters past the last frame are left out.
    init(glyph: Size, characters: String, columns: [ClosedRange<Int>?]) {
        let characters = Dictionary(characters.prefix(columns.count).enumerated().map { (String($1), $0) }) { first, _ in first }
        (self.glyph, self.characters, self.columns) = (glyph, characters, columns)
        digits = (0...9).compactMap { characters[String($0)].flatMap { columns[$0]?.count } }.max() ?? 0
    }

    /// Each frame's columns with a pixel in `opaque`: an image `width` pixels wide, row by row.
    static func measure(_ opaque: [Bool], width: Int, glyph: Size) -> [ClosedRange<Int>?] {
        let (across, down) = (width / glyph.width, opaque.count / width / glyph.height)
        return (0..<across * down).map { frame in
            let (left, top) = (frame % across * glyph.width, frame / across * glyph.height)
            let filled = (0..<glyph.width).filter { x in (top..<top + glyph.height).contains { opaque[$0 * width + left + x] } }
            return filled.first.map { $0...filled.last! }
        }
    }

    /// The glyph that draws `character`: its own, else the same letter in the other case, else "?". Spaces, and
    /// characters with no glyph in a font without "?", draw nothing but still take up space.
    func index(of character: Character) -> Int? {
        if let index = characters[String(character)] ?? characters[character.uppercased()] ?? characters[character.lowercased()] {
            return index
        }
        return character.isWhitespace ? nil : characters["?"]
    }

    /// Each glyph of `text`, wrapped to `width` if given, and where its frame goes, relative to the text's top-left
    /// corner, each line put in `width` as `align` says; and how wide the line it's on is, for text put around a point.
    func layout(_ text: String, width: Int? = nil, align: Screen.Align = .left) -> [(index: Int, x: Int, y: Int, line: Int)] {
        lines(text, width: width).enumerated().flatMap { row, line in
            let wide = self.width(of: line)
            var x = width.map { Int(Double($0 - wide) * align.share) } ?? 0
            return line.compactMap { character -> (index: Int, x: Int, y: Int, line: Int)? in
                let (drawn, advance) = place(character)
                defer { x += advance }
                return drawn.map { ($0.index, x + $0.x, row * glyph.height, wide) }
            }
        }
    }

    func size(of text: String, width: Int? = nil) -> Size {
        let lines = lines(text, width: width)
        return Size(lines.map { self.width(of: $0) }.max() ?? 0, lines.count * glyph.height)
    }

    /// How wide `text` draws on a line: how far the pen moves over it, but for the space after its last glyph, so
    /// text measured with it lines up with what's around it.
    func width(of text: some StringProtocol) -> Int {
        guard let last = text.last else { return 0 }
        return advance(text) - (place(last).glyph == nil ? 0 : 1)
    }

    /// The lines `text` draws as: split at `\n`, and given a `width`, at the last space before a word that would go
    /// past it, or inside a word wider than that.
    func lines(_ text: String, width: Int? = nil) -> [String] {
        let paragraphs = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let width else { return paragraphs }
        return paragraphs.flatMap { paragraph in
            var lines: [String] = [], line: String?
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                if let current = line, self.width(of: current + " " + word) <= width {
                    line = current + " " + word
                    continue
                }
                if let line { lines.append(line) }
                var rest = word
                while rest.count > 1, self.width(of: rest) > width { // wider than a line: break it where it stops fitting
                    var (fits, x) = (0, 0)
                    for character in rest {
                        let (drawn, advance) = place(character)
                        if x + advance - (drawn == nil ? 0 : 1) > width { break }
                        x += advance
                        fits += 1
                    }
                    lines.append(String(rest.prefix(max(fits, 1))))
                    rest = rest.dropFirst(max(fits, 1))
                }
                line = String(rest)
            }
            return lines + [line ?? ""]
        }
    }

    /// How far the pen moves over `text`.
    private func advance(_ text: some StringProtocol) -> Int { text.reduce(0) { $0 + place($1).advance } }

    /// The glyph that draws `character` and where its frame goes from the pen, and how far the pen moves on.
    /// The frame starts left of the pen by its empty columns; a digit's is centered in the widest digit's width.
    private func place(_ character: Character) -> (glyph: (index: Int, x: Int)?, advance: Int) {
        guard let index = index(of: character), let filled = columns[index] else { return (nil, (glyph.width + 1) / 2) }
        let width = ("0"..."9").contains(character) ? max(digits, filled.count) : filled.count
        return ((index, (width - filled.count) / 2 - filled.lowerBound), width + 1)
    }
}

extension Font {
    /// ASCII from space to "_": digits, capitals and punctuation. Lowercase letters draw as capitals.
    static let builtIn = Font(glyph: Size(4, 6), characters: String((32..<96).map { Character(UnicodeScalar(UInt8($0))) }),
                              columns: measure(builtInPixels, width: 64, glyph: Size(4, 6)))

    /// The built-in font's glyphs, white on clear.
    static func builtInTexture(_ gpu: GPU) -> GPUTexture {
        let pixels: [UInt32] = builtInPixels.map { $0 ? 0xFFFF_FFFF : 0 }
        return pixels.withUnsafeBytes { gpu.texture(rgba: $0, width: 64, height: 24)! }
    }

    /// `builtInArt` as 64x24 pixels, row by row: true where there's a "#".
    static let builtInPixels: [Bool] = {
        let rows = builtInArt.split(separator: "\n", omittingEmptySubsequences: false).map(Array.init)
        return (0..<24).flatMap { y in (0..<64).map { x in y < rows.count && x < rows[y].count && rows[y][x] == "#" } }
    }()

    /// One line per pixel row of a 64x24 image: 16 glyphs to a row in 4x6 frames, in `builtIn`'s order. "#" is a pixel.
    /// The blank lines are the space between lines of text.
    static let builtInArt = """
    ... .#. #.# #.# .## #.# .#. .#. ..# #.. ... ... ... ... ... ..#
    ... .#. #.# ### ##. ..# #.# .#. .#. .#. #.# .#. ... ... ... ..#
    ... .#. ... #.# .#. .#. .#. ... .#. .#. .#. ### ... ### ... .#.
    ... ... ... ### .## #.. #.# ... .#. .#. #.# .#. .#. ... ... #..
    ... .#. ... #.# ##. #.# .## ... ..# #.. ... ... #.. ... .#. #..

    ### .#. ##. ##. #.# ### .## ### ### ### ... ... ..# ... #.. ##.
    #.# ##. ..# ..# #.# #.. #.. ..# #.# #.# .#. .#. .#. ### .#. ..#
    #.# .#. .#. .#. ### ##. ### .#. ### ### ... ... #.. ... ..# .#.
    #.# .#. #.. ..# ..# ..# #.# .#. #.# ..# .#. .#. .#. ### .#. ...
    ### ### ### ##. ..# ##. ### .#. ### ##. ... #.. ..# ... #.. .#.

    .#. .#. ##. .## ##. ### ### .## #.# ### ..# #.# #.. #.# ##. .#.
    #.# #.# #.# #.. #.# #.. #.. #.. #.# .#. ..# #.# #.. ### #.# #.#
    ### ### ##. #.. #.# ##. ##. #.# ### .#. ..# ##. #.. ### #.# #.#
    #.. #.# #.# #.. #.# #.. #.. #.# #.# .#. #.# #.# #.. #.# #.# #.#
    .## #.# ##. .## ##. ### #.. .## #.# ### .#. #.# ### #.# #.# .#.

    ##. .#. ##. .## ### #.# #.# #.# #.# #.# ### ##. #.. .## .#. ...
    #.# #.# #.# #.. .#. #.# #.# #.# #.# #.# ..# #.. #.. ..# #.# ...
    ##. #.# ##. .#. .#. #.# #.# ### .#. .#. .#. #.. .#. ..# ... ...
    #.. ##. #.# ..# .#. #.# #.# ### #.# .#. #.. #.. ..# ..# ... ...
    #.. .## #.# ##. .#. ### .#. #.# #.# .#. ### ##. ..# .## ... ###
    """
}
