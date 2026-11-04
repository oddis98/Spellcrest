import Foundation
import SpellcrestProtocol
import Synchronization

/// Someone made of the game's kit of parts as it runs, from `Assets/Parts`, as the editor's character builder makes
/// them: for gear that changes in play. Put a helmet on, and the sprite wears it, its animation going on.
///
///     var hero = Person("hero") // as Assets/People/hero.person has them
///     player.sprite = Sprite(hero)
///     hero.parts["hat"] = "helmet"
///     player.sprite?.wear(hero)
///
/// Its image is made the first time it's drawn, and again when one of its parts changes, as the editor saves them; the
/// same look is the same image, however many wear it. Its attack and cast are what its weapon makes them, as the kit's
/// actions say.
public struct Person: Hashable, Sendable {
    /// The part in each of the kit's slots, by name, like "hat": "helmet"; a slot not here is empty.
    public var parts: [String: String]
    /// The ramp worn of each material, by name, like "metal": "gold"; a material not here is worn as its parts are drawn.
    public var wears: [String: String]

    public init(parts: [String: String] = [:], wears: [String: String] = [:]) { (self.parts, self.wears) = (parts, wears) }

    /// As `<name>.person` in Assets has them, as the builder saved it; nobody if it can't be read, which the console says.
    public init(_ name: String) {
        do {
            let file = try PersonFile(contentsOf: assetURL("\(name).person"))
            self.init(parts: file.parts, wears: file.wears ?? [:])
        } catch {
            say(once: "\(name).person", "Spellcrest: can't read \(name).person, so it's nobody: \(error.localizedDescription)")
            self.init()
        }
    }

    /// The image this look makes, which a sprite draws as it draws an image file's.
    public var image: ImageName { ImageName(Self.prefix + String(decoding: try! Self.encoder.encode(file), as: UTF8.self)) }

    var file: PersonFile { PersonFile(parts: parts, wears: wears.isEmpty ? nil : wears) }

    /// The look an image's name is, if it's a person's.
    init?(image name: String) {
        guard name.hasPrefix(Self.prefix), let file = try? JSONDecoder().decode(PersonFile.self, from: Data(name.dropFirst(Self.prefix.count).utf8)) else {
            return nil
        }
        self.init(parts: file.parts, wears: file.wears ?? [:])
    }

    static let prefix = "person:"
    private static let encoder = { // the same look, the same name
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()
}

public extension Sprite {
    /// A sprite of someone made of the kit's parts.
    init(_ person: Person) { self.init(person.image) }

    /// Draws `person`'s look from now on, its animation going on: gear put on or taken off in play.
    mutating func wear(_ person: Person) { image = person.image.name }
}

/// A person's image, made of the kit's parts, and how it's cut up; and the files it was made from, to make it again
/// when one changes.
struct MadePerson {
    var pixels: [UInt32] // 0xRRGGBBAA, straight alpha, as sprites blend
    var width, height: Int
    var sheet: SheetFile
    var files: [String] // in Assets
}

extension Person {
    /// The kit, `Parts/kit.json`, which isn't among the files games find by name: read again once it changes.
    static func kit() throws -> KitFile {
        let url = assetURL("Parts/kit.json"), date = modificationDate(url)
        if let kit = kitRead.withLock({ $0.url == url && $0.date == date && date != nil ? $0.kit : nil }) { return kit }
        let kit = try KitFile(contentsOf: url)
        kitRead.withLock { $0 = (url, date, kit) }
        return kit
    }

    /// Its image, its parts stacked in the shades it wears, as the builder makes it.
    func make() throws -> MadePerson {
        let kit = try Self.kit()
        var files = ["Parts/kit.json"]
        let (pixels, width) = try file.compose(kit) { path in
            files.append("Parts/\(path).png")
            return try readPixels(assetURL("Parts/\(path).png"))
        }
        return MadePerson(pixels: pixels, width: width, height: pixels.count / max(width, 1), sheet: file.sheet(kit), files: files)
    }
}

extension Screen {
    /// A person's image, made the first time it's drawn; nobody, and the console says why, if it can't be made.
    func personTexture(_ name: String) -> GPUTexture {
        guard let made = madePerson(name) else { return clear }
        let bytes = made.pixels.map(\.bigEndian) // memory order R, G, B, A
        guard let texture = bytes.withUnsafeBytes({ gpu.texture(rgba: $0, width: made.width, height: made.height) }) else { return clear }
        textures[name] = texture
        return texture
    }

    /// A person's image as made, its sheet kept, and its files watched to make it again; nil if it can't be made.
    func madePerson(_ name: String) -> MadePerson? {
        guard let person = Person(image: name) else { return nil }
        do {
            let made = try person.make()
            sheets[name] = .some(made.sheet)
            for file in made.files {
                if modified[file] == nil { modified[file] = modificationDate(assetURL(file)) }
                wearing[file, default: []].insert(name)
            }
            return made
        } catch {
            if warned.insert(name).inserted { print("Spellcrest: can't make \(person.parts.sorted { $0.key < $1.key }) of the kit's parts: \(error)") }
            textures[name] = clear
            sheets[name] = .some(nil)
            return nil
        }
    }

    /// The people made of a part, or of the kit, that changed on disk: made again when next drawn.
    func remakePeople(wearing file: String) {
        for name in wearing[file] ?? [] { (textures[name], sheets[name]) = (nil, nil) }
        warned = warned.filter { !$0.hasPrefix(Person.prefix) }
    }
}

let kitRead = Mutex<(url: URL?, date: Date?, kit: KitFile?)>((nil, nil, nil)) // the kit last read, while its file is as it was
