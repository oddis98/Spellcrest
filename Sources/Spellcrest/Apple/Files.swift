#if canImport(Darwin)
import Foundation

/// The app's `Assets` folder, once the game is exported as an app; nil while it runs from its package's folder.
func appAssets() -> URL? { Bundle.main.url(forResource: "Assets", withExtension: nil) }

/// Where saves go: `~/Library/Application Support/<game>/` on the Mac, `<game>` being the executable's name, the same
/// when the editor runs it as once it's exported; and the app's own Application Support folder on iOS.
func savesFolder() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    #if os(macOS)
    return support.appending(path: ProcessInfo.processInfo.processName)
    #else
    return support
    #endif
}
#endif
