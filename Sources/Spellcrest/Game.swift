#if os(macOS)
import AppKit
#else
import UIKit
#endif
import GameController
import SpellcrestProtocol

/// A Spellcrest game. Mark your conforming type `@main` and Spellcrest opens a window and runs it (on iOS, the app's
/// screen, with touch controls over it).
@MainActor public protocol Game {
    /// Makes the game as it starts, before its first scene: a struct with nothing to set needs no `init` of its own.
    init()
    /// Size of the pixel canvas. The window scales it up by whole numbers so pixels stay square and crisp.
    var resolution: Size { get }
    /// The canvas for the display the game is shown on, on an iPhone or iPad: asked once the game's view has its shape
    /// and safe area, and again whenever they change, as the device turns or a foldable opens, so the canvas can fill
    /// the screen either way. The scene hears of a change (`Scene.resized(from:)`). It's `resolution` unless the game
    /// says otherwise; the Mac's window and the editor's preview keep `resolution`.
    func resolution(for display: Display) -> Size
    /// The scene the game starts in.
    func start() -> Scene
}

/// What a game is shown on, on an iPhone or iPad: its size in points, across and down as it's held, and how far in from
/// each edge the system needs room, its safe area: the island or a camera at the top, or at a side held sideways, and
/// the home indicator at the bottom.
public struct Display: Sendable, Equatable {
    /// Across, in points, as it's held.
    public var width: Double
    /// Down, in points, as it's held.
    public var height: Double
    /// How far down from the top the safe area starts, in points: the island, upright.
    public var top: Double
    /// How far in from the left it starts: a camera's room, held sideways.
    public var left: Double
    /// How far up from the bottom it ends: the home indicator.
    public var bottom: Double
    /// How far in from the right it ends.
    public var right: Double

    /// A display `width` by `height` points, with these insets.
    public init(width: Double, height: Double, top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        (self.width, self.height, self.top, self.left, self.bottom, self.right) = (width, height, top, left, bottom, right)
    }

    /// Wider than it's tall: an iPhone held sideways.
    public var sideways: Bool { width > height }
}

/// A position or velocity in pixels.
public typealias Vector = SIMD2<Double>

/// A width and height in pixels, like a game's `resolution`. It's `Codable`, so a save can keep one.
public struct Size: Sendable, Equatable, Codable {
    /// Across, in pixels.
    public var width: Int
    /// Down, in pixels.
    public var height: Int

    /// A size `width` pixels across and `height` down: `Size(320, 180)`.
    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in pixels: its top-left corner and its size, like an entity's `hitbox`. It's `Codable`, so a save can
/// keep one.
public struct Rect: Sendable, Equatable, Codable {
    /// Its left edge, in pixels.
    public var x: Int
    /// Its top edge, in pixels, y going down.
    public var y: Int
    /// Across, in pixels.
    public var width: Int
    /// Down, in pixels.
    public var height: Int

    /// The rectangle with its top-left corner at (`x`, `y`), `width` pixels across and `height` down.
    public init(x: Int, y: Int, width: Int, height: Int) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    /// True when the two overlap by a pixel or more.
    public func intersects(_ other: Rect) -> Bool {
        x < other.x + other.width && other.x < x + width && y < other.y + other.height && other.y < y + height
    }

    /// True when `point` is in it, like `Input.pointer` on a button drawn in canvas pixels.
    public func contains(_ point: Vector) -> Bool {
        point.x >= Double(x) && point.x < Double(x + width) && point.y >= Double(y) && point.y < Double(y + height)
    }
}

/// An image in the game's `Assets`, by its file's name without ".png": a sprite, a tileset, a font or a text box. The
/// editor names each of the game's images, maps, sounds, objects and shaders in `Sources/<Game>/AssetNames.swift`, as
/// Xcode does an asset catalog's, so `Sprite(.slime)` completes, and a typo, or an asset renamed or deleted, is an
/// error where it's used rather than a crash when the game gets there. `ImageName(name)` names one that comes from
/// data. It's `Codable`, saved as its name, so a save that kept the name as a `String` reads as one.
public struct ImageName: Hashable, Sendable, Codable {
    /// The file's name, without ".png".
    public let name: String
    /// The image called `name`, for one that comes from data; the names file has a `static let` for each of the game's.
    public init(_ name: String) { self.name = name }
    /// Reads one saved as its name.
    public init(from decoder: Decoder) throws { name = try decoder.singleValueContainer().decode(String.self) }
    /// Saves it as its name.
    public func encode(to encoder: Encoder) throws { try save(name, to: encoder) }
}

/// A level in the game's `Assets`, by its `.tilemap` file's name: `Tilemap(.level1)`. See `ImageName`, which says how
/// it's saved too.
public struct MapName: Hashable, Sendable, Codable {
    /// The file's name, without ".tilemap".
    public let name: String
    /// The map called `name`, for one that comes from data, like a door's `to`.
    public init(_ name: String) { self.name = name }
    /// Reads one saved as its name.
    public init(from decoder: Decoder) throws { name = try decoder.singleValueContainer().decode(String.self) }
    /// Saves it as its name.
    public func encode(to encoder: Encoder) throws { try save(name, to: encoder) }
}

/// A sound effect or music track in the game's `Assets`, by its file's name without its type (.wav, .m4a, .mp3 or
/// .caf): `Sound.play(.jump)`, `Music.play(.theme)`. See `ImageName`, which says how it's saved too.
public struct SoundName: Hashable, Sendable, Codable {
    /// The file's name, without its type.
    public let name: String
    /// The sound called `name`, for one that comes from data.
    public init(_ name: String) { self.name = name }
    /// Reads one saved as its name.
    public init(from decoder: Decoder) throws { name = try decoder.singleValueContainer().decode(String.self) }
    /// Saves it as its name.
    public func encode(to encoder: Encoder) throws { try save(name, to: encoder) }
}

/// An object maps place, by its definition's name, `Assets/Objects/<name>.object`: `tilemap.objects(named: .start)`,
/// or `object.name == .door` for a placed one. See `ImageName`, which says how it's saved too.
public struct ObjectName: Hashable, Sendable, Codable {
    /// The definition's file name, without ".object", which a placed object has as its `name`.
    public let name: String
    /// The object called `name`, for one that comes from data, like a den's `creature`.
    public init(_ name: String) { self.name = name }
    /// Reads one saved as its name.
    public init(from decoder: Decoder) throws { name = try decoder.singleValueContainer().decode(String.self) }
    /// Saves it as its name.
    public func encode(to encoder: Encoder) throws { try save(name, to: encoder) }

    /// Whether a placed object's name is this one's: `object.name == .door`.
    public static func == (name: String, object: ObjectName) -> Bool { name == object.name }
    /// Whether a placed object's name isn't this one's: `object.name != .door`.
    public static func != (name: String, object: ObjectName) -> Bool { name != object.name }
}

/// Saves an asset's `name` as the whole of its name's value, a plain string.
func save(_ name: String, to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(name)
}

/// The game's own files in `Assets`, beside its art and maps: a level's data, a list of words.
public enum Assets {
    /// The file called `file`, with its type, in `Assets` or a folder in it: `Assets.url("words.txt")`. It's found by
    /// name as the engine finds an image, outside an app in the folder the game runs in and in an app inside it, where
    /// a path like `Assets/words.txt` isn't. Nil when there's none.
    public static func url(_ file: String) -> URL? {
        let url = assetURL(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

public extension Game {
    /// 320×180 pixels, a sixth of 1080p, unless the game says otherwise.
    var resolution: Size { Size(320, 180) }

    /// The game's `resolution`, whatever it's shown on, unless the game says otherwise.
    func resolution(for display: Display) -> Size { resolution }

    /// What `@main` runs: makes the game and its first scene, then opens a window and runs it, or in the editor sends
    /// it to the preview, or on iOS starts the app.
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0) // print() reaches the editor console line by line, not when a buffer fills
        Scene.module = String(String(reflecting: Self.self).prefix { $0 != "." }) // where objects' classes are
        let game = Self()
        Input.canvas = game.resolution // for the first scene to lay itself out by, before there's a loop
        Scene.current = game.start()
        #if os(macOS)
        if let path = ProcessInfo.processInfo.environment[Message.environmentKey], let channel = Channel.connect(to: path) {
            runInEditor(game.resolution, channel)
        } else {
            runInWindow(game.resolution)
        }
        #else
        GameApp.resolution = game.resolution
        GameApp.game = game
        _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(GameApp.self))
        #endif
    }
    #if os(macOS)

    /// Run by the editor: no window or Dock icon, the editor's preview shows the frames.
    private static func runInEditor(_ size: Size, _ channel: Channel) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        GCController.shouldMonitorBackgroundEvents = true // game controllers keep working while the editor is in front
        let host = EditorHost(resolution: size, channel: channel)
        channel.listen { message in
            DispatchQueue.main.async { MainActor.assumeIsolated { host.handle(message) } }
        } closed: {
            exit(0) // the editor stopped us or went away
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { host.frame() } }
        app.run()
    }

    private static func runInWindow(_ size: Size) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular) // the editor runs games as bare executables, which need this; harmless in an app
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(Self.self)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.mainMenu = NSMenu()
        app.mainMenu!.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let view = GameView(resolution: size)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width * 3, height: size.height * 3),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(Self.self)"
        window.contentMinSize = NSSize(width: size.width, height: size.height)
        window.contentView = view
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true // the mouse over the game, without its button
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            exit(0) // closing the window quits the game
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { // key-ups and the mouse go elsewhere once we lose focus
                Input.keys.removeAll()
                Input.point(nil, down: false)
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        withExtendedLifetime(window) { app.run() }
    }
    #endif
}

/// Keeps a game's progress between runs: any `Codable` value, as `<name>.json` in `~/Library/Application Support/<game>/`
/// on the Mac (`<game>` being the executable's name, the same when the editor runs it as once it's exported), and in
/// the app's own Application Support folder on iOS.
@MainActor public enum Save {
    static var folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return support.appending(path: ProcessInfo.processInfo.processName)
        #else
        return support
        #endif
    }()

    /// Where saves are written, in order, off the main thread: writing one took 4 to 7 ms on an iPhone, which a game that
    /// saves every second, like Driftwood, paid in a frame each second.
    nonisolated static let writes = DispatchQueue(label: "Spellcrest saves")
    /// Saves still being written are written before the game quits.
    private static let finishedOnExit: Void = { atexit { Save.writes.sync {} } }()

    /// Saves `value` as `<name>.json` in one step, so quitting halfway never leaves half a save: encoded at once, then
    /// written off the main thread. If it can't be, the console says why.
    public static func write(_ value: some Encodable, to name: String) {
        _ = finishedOnExit
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do { data = try encoder.encode(value) } catch { return print("Spellcrest: can't save \(name): \(error.localizedDescription)") }
        let file = folder.appending(path: "\(name).json")
        writes.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                print("Spellcrest: can't save \(name): \(error.localizedDescription)")
            }
        }
    }

    /// What was saved as `<name>.json`; nil if nothing was, or if it no longer decodes because its type changed while
    /// the game was being made (the console says why).
    public static func read<Value: Decodable>(_ type: Value.Type, from name: String) -> Value? {
        writes.sync {} // after the saves still being written
        let file = folder.appending(path: "\(name).json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            print("Spellcrest: \(file.path) no longer reads as \(type), so it's ignored: \(error)")
            return nil
        }
    }
}
