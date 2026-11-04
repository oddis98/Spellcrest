import Foundation

/// Steam, for a game sold there: its achievements and stats, and the player's Steam name. It goes through Steam's own
/// library, `libsteam_api.dylib` from the Steamworks SDK, which the editor's Export for Steam puts in the app; while
/// the game is being made, the editor's Run finds it in the SDK the editor's Settings name (`STEAMWORKS_SDK`), or a
/// copy can go in the game's folder. Without the library, or with Steam not running, Steam stays off (`isRunning` is
/// false) and the rest does nothing, so the game plays on as it would anywhere else.
@MainActor public enum Steam {
    /// Starts Steam for the game whose Steam app ID is `appID`: call it first thing in the game's `start()`, before its
    /// window is made, so Steam's overlay can draw over it. An app started other than by Steam quits, and Steam starts it
    /// again, as Valve asks; a game run from its package's folder, as the editor runs it, plays on, Steam told its app
    /// ID. If Steam can't start, the console says why.
    public static func start(appID: UInt32) {
        guard running == nil, let library = Library.load() else { return }
        switch start(appID: appID, with: library, inApp: Bundle.main.bundleURL.pathExtension == "app") {
        case .restarting: exit(0) // Steam starts it again
        case let .failed(why): print("Spellcrest: Steam didn't start, so the game plays without it: \(why)")
        case .running: break
        }
    }

    /// Whether Steam started for the game.
    public static var isRunning: Bool { running != nil }

    /// The player's Steam name; nil while Steam isn't running.
    public static var name: String? {
        guard let running, let friends = running.friends, let name = running.library.personaName(friends) else { return nil }
        return String(cString: name)
    }

    /// Unlocks the achievement whose API name is `name`, as the game's Steamworks page gives it, and has Steam keep it at
    /// once. One already unlocked stays so. If the page has no such achievement, the console says so, once.
    public static func achieve(_ name: String) {
        guard let running, let stats = running.stats else { return }
        if !running.library.setAchievement(stats, name), said.insert("achievement \(name)").inserted {
            print("Spellcrest: Steam has no achievement \"\(name)\": its API name on the game's Steamworks page, under Stats & Achievements")
        }
        _ = running.library.storeStats(stats)
    }

    /// Sets the stat whose API name is `name`, a whole number on the game's Steamworks page, to `value`, and has Steam
    /// keep it at once: an achievement unlocked by a stat, as "100 bells rung" is, unlocks as it gets there.
    public static func stat(_ name: String, _ value: Int) {
        guard let running, let stats = running.stats else { return }
        if !running.library.setStat(stats, name, Int32(clamping: value)), said.insert("stat \(name)").inserted {
            print("Spellcrest: Steam has no stat \"\(name)\" that's a whole number: its API name on the game's Steamworks page")
        }
        _ = running.library.storeStats(stats)
    }

    /// Steam once it's started: its library, and the interfaces the game uses.
    struct Running {
        let library: Library
        let stats: OpaquePointer?
        let friends: OpaquePointer?
    }
    static var running: Running?
    static var said: Set<String> = [] // what the console has said, once each

    enum Started: Equatable {
        case running, restarting, failed(String)
    }

    /// Starts Steam through `library`: Steam starts an app it didn't start again, and outside an app is told the app ID,
    /// as Steam tells a game it starts (`SteamAppId`), where it would read a `steam_appid.txt`; then the game's
    /// interfaces are found, and Steam's callbacks run 60 times a second from then on, as Valve asks of every game, on
    /// the main run loop.
    static func start(appID: UInt32, with library: Library, inApp: Bool) -> Started {
        if inApp, library.restartAppIfNecessary(appID) { return .restarting }
        if !inApp { setenv("SteamAppId", String(appID), 0) } // one Steam set, starting the game itself, stays
        if let why = library.initialize() { return .failed(why) }
        let stats = library.userStats()
        if let stats, let request = library.requestCurrentStats { _ = request(stats) } // an older SDK's, which wants the stats first
        running = Running(library: library, stats: stats, friends: library.friends())
        shutdown = library.shutdown
        atexit(shutDown)
        let callbacks = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in library.runCallbacks() }
        RunLoop.main.add(callbacks, forMode: .common)
        return .running
    }
}

/// `SteamAPI_Shutdown`, run as the game quits (`shutDown`).
nonisolated(unsafe) private var shutdown: (@convention(c) () -> Void)?

/// Shuts Steam down as the game quits, on whatever thread quits it, as the editor's Stop does from its socket's: a
/// closure written in `Steam` would be the main actor's, and its check of that trapped.
private func shutDown() { shutdown?() }

/// The functions of Steam's library the game uses, from its flat interface, which any language can call. Found by
/// name in the library as it's loaded rather than linked, so a game without it builds and runs, and no file of the
/// Steamworks SDK, whose license keeps it to the games made with it, needs to be in the engine.
struct Library: @unchecked Sendable {
    let restartAppIfNecessary: @convention(c) (UInt32) -> Bool
    /// Starts the library: nil once it has, or why it didn't.
    let initialize: () -> String?
    let runCallbacks: @convention(c) () -> Void
    let shutdown: @convention(c) () -> Void
    let userStats: @convention(c) () -> OpaquePointer?
    let requestCurrentStats: (@convention(c) (OpaquePointer?) -> Bool)?
    let setAchievement: @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Bool
    let setStat: @convention(c) (OpaquePointer?, UnsafePointer<CChar>, Int32) -> Bool
    let storeStats: @convention(c) (OpaquePointer?) -> Bool
    let friends: @convention(c) () -> OpaquePointer?
    let personaName: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

    /// The library from `symbol`, which finds each function by its name; nil if one the game needs isn't there.
    init?(_ symbol: (String) -> UnsafeMutableRawPointer?) {
        func function<Function>(_ name: String, as type: Function.Type) -> Function? {
            symbol(name).map { unsafeBitCast($0, to: type) }
        }
        /// An interface's accessor, `SteamAPI_SteamUserStats_v013`, of the newest version the library has.
        func accessor(_ interface: String) -> (@convention(c) () -> OpaquePointer?)? {
            for version in (1...40).reversed() {
                let digits = String(version), name = "SteamAPI_\(interface)_v" + String(repeating: "0", count: 3 - digits.count) + digits
                if let accessor = function(name, as: (@convention(c) () -> OpaquePointer?).self) { return accessor }
            }
            return nil
        }
        let initialize: () -> String?
        if let flat = function("SteamAPI_InitFlat", as: (@convention(c) (UnsafeMutablePointer<CChar>?) -> Int32).self) {
            initialize = { // SDK 1.59 and later: a result, and why in a SteamErrMsg, 1024 characters
                var message = [CChar](repeating: 0, count: 1024)
                let result = flat(&message)
                let why = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return result == 0 ? nil : why.isEmpty ? "result \(result)" : why
            }
        } else if let old = function("SteamAPI_Init", as: (@convention(c) () -> Bool).self) {
            initialize = { old() ? nil : "Steam isn't running, or doesn't know the app ID" }
        } else {
            return nil
        }
        guard let restart = function("SteamAPI_RestartAppIfNecessary", as: (@convention(c) (UInt32) -> Bool).self),
              let runCallbacks = function("SteamAPI_RunCallbacks", as: (@convention(c) () -> Void).self),
              let shutdown = function("SteamAPI_Shutdown", as: (@convention(c) () -> Void).self),
              let userStats = accessor("SteamUserStats"), let friends = accessor("SteamFriends"),
              let setAchievement = function("SteamAPI_ISteamUserStats_SetAchievement", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Bool).self),
              let setStat = function("SteamAPI_ISteamUserStats_SetStatInt32", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>, Int32) -> Bool).self),
              let storeStats = function("SteamAPI_ISteamUserStats_StoreStats", as: (@convention(c) (OpaquePointer?) -> Bool).self),
              let personaName = function("SteamAPI_ISteamFriends_GetPersonaName", as: (@convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?).self)
        else { return nil }
        (self.restartAppIfNecessary, self.initialize, self.runCallbacks, self.shutdown) = (restart, initialize, runCallbacks, shutdown)
        (self.userStats, self.setAchievement, self.setStat, self.storeStats) = (userStats, setAchievement, setStat, storeStats)
        (self.friends, self.personaName) = (friends, personaName)
        requestCurrentStats = function("SteamAPI_ISteamUserStats_RequestCurrentStats", as: (@convention(c) (OpaquePointer?) -> Bool).self)
    }

    /// Steam's library where a game finds it: in an app's Frameworks folder, beside the game, in the folder it runs in,
    /// or in the Steamworks SDK that `STEAMWORKS_SDK` names, as the editor's Run does; nil where there's none, or on a
    /// platform without Steam.
    static func load() -> Library? {
        #if os(macOS)
        let file = "libsteam_api.dylib", sdk = ProcessInfo.processInfo.environment["STEAMWORKS_SDK"]
        let places = [Bundle.main.privateFrameworksURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                      URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                      sdk.map { URL(fileURLWithPath: $0).appending(path: "redistributable_bin/osx") }].compactMap { $0?.appending(path: file) }
        for place in places where FileManager.default.fileExists(atPath: place.path) {
            guard let handle = dlopen(place.path, RTLD_NOW | RTLD_LOCAL) else {
                print("Spellcrest: can't load \(place.path), so the game plays without Steam: \(dlerror().map { String(cString: $0) } ?? "")")
                return nil
            }
            guard let library = Library({ dlsym(handle, $0) }) else {
                print("Spellcrest: \(place.path) isn't a Steamworks SDK's library Spellcrest knows, so the game plays without Steam")
                return nil
            }
            return library
        }
        #endif
        return nil
    }
}
