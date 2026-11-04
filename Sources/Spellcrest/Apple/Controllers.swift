#if canImport(GameController)
import GameController

extension Input.Device {
    /// What a player starts as using: touch on iOS, the keyboard on a Mac.
    #if os(iOS)
    static let standard = Input.Device.touch
    #else
    static let standard = Input.Device.keyboard
    #endif
}

extension Input {
    static weak var heard: GCExtendedGamepad? // the controller whose handler fills `pushed`

    /// The current game controller's buttons, and its left stick, y going down; none without one.
    static func controller() -> (held: Set<Button>, stick: Vector) {
        guard let gamepad = GCController.current?.extendedGamepad else { return ([], .zero) }
        hear(gamepad)
        return (buttons(of: gamepad), [Double(gamepad.leftThumbstick.xAxis.value), -Double(gamepad.leftThumbstick.yAxis.value)])
    }

    /// What a controller holds: its D-pad, or its left stick past half way, as the D-pad's buttons, and A, B, X, Y and Menu.
    nonisolated static func buttons(of gamepad: GCExtendedGamepad) -> Set<Button> {
        var held: Set<Button> = []
        let (x, y) = (gamepad.leftThumbstick.xAxis.value, gamepad.leftThumbstick.yAxis.value)
        if gamepad.dpad.left.isPressed || x < -0.5 { held.insert(.left) }
        if gamepad.dpad.right.isPressed || x > 0.5 { held.insert(.right) }
        if gamepad.dpad.up.isPressed || y > 0.5 { held.insert(.up) }
        if gamepad.dpad.down.isPressed || y < -0.5 { held.insert(.down) }
        if gamepad.buttonA.isPressed { held.insert(.a) }
        if gamepad.buttonB.isPressed { held.insert(.b) }
        if gamepad.buttonX.isPressed { held.insert(.x) }
        if gamepad.buttonY.isPressed { held.insert(.y) }
        if gamepad.buttonMenu.isPressed { held.insert(.start) }
        return held
    }

    /// Hears a controller's buttons as they change, on the main queue (`GCController.handlerQueue`'s own), so one pressed
    /// and let go between two updates still counts at the next.
    private static func hear(_ gamepad: GCExtendedGamepad) {
        guard gamepad !== heard else { return }
        heard = gamepad
        gamepad.valueChangedHandler = { gamepad, _ in
            let held = buttons(of: gamepad)
            MainActor.assumeIsolated { pushed.formUnion(held) }
        }
    }
}
#endif
