import Foundation
@testable import SpellcrestSteam
import Testing

// Stand-ins for Steam's library, each saying what it was asked, in order.
nonisolated(unsafe) private var asked: [String] = []
nonisolated(unsafe) private var restarts = false
nonisolated(unsafe) private var started: Int32 = 0 // what SteamAPI_InitFlat gives: 0 started, 2 no Steam running
nonisolated(unsafe) private let stats = OpaquePointer(bitPattern: 0x5157), friends = OpaquePointer(bitPattern: 0xF12E)

private let restart: @convention(c) (UInt32) -> Bool = { app in
    asked.append("restart \(app)")
    return restarts
}
private let initFlat: @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32 = { message in
    asked.append("init")
    if started != 0, let message { _ = "No Steam client".withCString { strcpy(message, $0) } }
    return started
}
private let none: @convention(c) () -> Void = {}
private let userStats: @convention(c) () -> OpaquePointer? = { stats }
private let olderUserStats: @convention(c) () -> OpaquePointer? = { nil }
private let steamFriends: @convention(c) () -> OpaquePointer? = { friends }
private let setAchievement: @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Bool = { on, name in
    asked.append("achieve \(String(cString: name))\(on == stats ? "" : " elsewhere")")
    return String(cString: name) != "missing"
}
private let setStat: @convention(c) (OpaquePointer?, UnsafePointer<CChar>, Int32) -> Bool = { _, name, value in
    asked.append("stat \(String(cString: name)) \(value)")
    return true
}
private let storeStats: @convention(c) (OpaquePointer?) -> Bool = { _ in
    asked.append("store")
    return true
}
private let personaName: @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>? = { _ in
    UnsafeRawPointer(("Rowan" as StaticString).utf8Start).assumingMemoryBound(to: CChar.self)
}

/// The stand-ins by the names Steam's library gives its functions, but `missing`.
private func symbol(_ name: String, missing: String? = nil) -> UnsafeMutableRawPointer? {
    guard name != missing else { return nil }
    return switch name {
    case "SteamAPI_RestartAppIfNecessary": unsafeBitCast(restart, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_InitFlat": unsafeBitCast(initFlat, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_RunCallbacks", "SteamAPI_Shutdown": unsafeBitCast(none, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_SteamUserStats_v013": unsafeBitCast(userStats, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_SteamUserStats_v012": unsafeBitCast(olderUserStats, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_SteamFriends_v017": unsafeBitCast(steamFriends, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_ISteamUserStats_SetAchievement": unsafeBitCast(setAchievement, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_ISteamUserStats_SetStatInt32": unsafeBitCast(setStat, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_ISteamUserStats_StoreStats": unsafeBitCast(storeStats, to: UnsafeMutableRawPointer.self)
    case "SteamAPI_ISteamFriends_GetPersonaName": unsafeBitCast(personaName, to: UnsafeMutableRawPointer.self)
    default: nil
    }
}

@MainActor @Suite(.serialized) struct SteamTests {
    init() { (asked, restarts, started, Steam.running) = ([], false, 0, nil) }

    @Test func aGameWithoutSteamsLibraryPlaysWithoutIt() {
        #expect(Library.load() == nil) // none beside the tests, nor in the folder they run in
        Steam.start(appID: 480)
        Steam.achieve("first-bell")
        Steam.stat("bells", 3)
        #expect(!Steam.isRunning && Steam.name == nil && asked.isEmpty)
    }

    @Test func steamStartsAGameItDidntStartAgain() throws {
        restarts = true
        #expect(Steam.start(appID: 480, with: try #require(Library { symbol($0) }), inApp: true) == .restarting)
        #expect(asked == ["restart 480"] && !Steam.isRunning)
    }

    @Test func aGameSteamStartedKeepsItsAchievementsAndStatsOnTheNewestInterfaces() throws {
        #expect(Steam.start(appID: 480, with: try #require(Library { symbol($0) }), inApp: true) == .running)
        Steam.achieve("first-bell")
        Steam.stat("bells", 3)
        Steam.achieve("missing") // which the console says Steam hasn't, once
        Steam.stat("score", 5_000_000_000) // kept within a stat's 32 bits
        #expect(Steam.isRunning && Steam.name == "Rowan")
        #expect(asked == ["restart 480", "init", "achieve first-bell", "store", "stat bells 3", "store", "achieve missing", "store",
                          "stat score \(Int32.max)", "store"])
    }

    @Test func steamThatDoesntStartSaysWhyAndTheGamePlaysOn() throws {
        started = 2
        #expect(Steam.start(appID: 480, with: try #require(Library { symbol($0) }), inApp: true) == .failed("No Steam client"))
        Steam.achieve("first-bell")
        #expect(!Steam.isRunning && asked == ["restart 480", "init"])
    }

    @Test func aGameRunFromItsFolderTellsSteamItsAppIDRatherThanBeingStartedAgain() throws {
        (restarts, started) = (true, 0)
        unsetenv("SteamAppId")
        #expect(Steam.start(appID: 480, with: try #require(Library { symbol($0) }), inApp: false) == .running)
        #expect(asked == ["init"] && ProcessInfo.processInfo.environment["SteamAppId"] == "480")
        unsetenv("SteamAppId")
    }

    @Test func aLibraryWithoutAFunctionTheGameNeedsIsntUsed() {
        #expect(Library { symbol($0, missing: "SteamAPI_ISteamUserStats_StoreStats") } == nil)
        #expect(Library { symbol($0, missing: "SteamAPI_InitFlat") } == nil) // nor SteamAPI_Init, an older SDK's
    }
}
