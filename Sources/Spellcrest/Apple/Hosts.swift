#if os(macOS)
import AppKit
import GameController
import SpellcrestProtocol

extension Game {
    /// Runs the game: in the editor, which launched it with its socket's path, sending each frame to its preview; or
    /// else in a window of its own.
    static func host(_ game: Self) {
        if let path = ProcessInfo.processInfo.environment[Message.environmentKey], let channel = Channel.connect(to: path) {
            runInEditor(game.resolution, channel)
        } else {
            runInWindow(game.resolution)
        }
    }

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
}
#elseif os(iOS)
import UIKit

extension Game {
    /// Starts the app around the game, which UIKit runs (`GameApp`).
    static func host(_ game: Self) {
        GameApp.resolution = game.resolution
        GameApp.game = game
        _ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(GameApp.self))
    }
}
#endif
