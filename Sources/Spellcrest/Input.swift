#if os(macOS)
import Carbon.HIToolbox // kVK_ key codes
#endif
import GameController

/// A virtual gamepad. Keyboard: arrows or WASD, Z or Space = a, X = b, C = x, V = y, Return or Escape = start.
/// Game controllers: d-pad or left stick, A, B, X, Y, Menu. On iOS, also the touch controls over the game.
/// And the pointer's press: the mouse's button, or a finger on the game.
public enum Button: Sendable, CaseIterable {
    /// Left on the D-pad or the stick, the left arrow or A on a keyboard.
    case left
    /// Right on the D-pad or the stick, the right arrow or D.
    case right
    /// Up on the D-pad or the stick, the up arrow or W.
    case up
    /// Down on the D-pad or the stick, the down arrow or S.
    case down
    /// A, the button that jumps or acts: Z or Space on a keyboard.
    case a
    /// B, which cancels or swings: X on a keyboard.
    case b
    /// X: C on a keyboard.
    case x
    /// Y: V on a keyboard.
    case y
    /// Start, for a menu or a pause: Menu on a controller, Return or Escape on a keyboard.
    case start
    /// The mouse's button down on the game, or on iOS a finger on it that didn't land on the touch controls;
    /// `Input.pointer` says where.
    case pointer
}

/// The virtual gamepad and the pointer, read in `update`: `Input.held(.right)`, `Input.pressed(.a)`,
/// `Input.released(.a)`, `Input.pressed(.pointer)`; `Input.direction` for where the player's pushing; and the keyboard's
/// own keys, for what a gamepad has no button for: `Input.pressed(key: .escape)`. A button pressed and let go between
/// two updates counts at the next, as pressed then, and as let go at the one after.
@MainActor public enum Input {
    /// True while the button is down.
    public static func held(_ button: Button) -> Bool { now.contains(button) }

    /// True only on the update when the button goes down.
    public static func pressed(_ button: Button) -> Bool { now.contains(button) && !before.contains(button) }

    /// True only on the update when the button goes up: for what happens as it's let go, like a jump cut short or a
    /// bow loosed.
    public static func released(_ button: Button) -> Bool { !now.contains(button) && before.contains(button) }

    /// True while the key is down on a Mac's keyboard or an iPad's: `Input.held(key: .shift)`.
    public static func held(key: Key) -> Bool { keysNow.contains(key) }

    /// True only on the update when the key goes down: `Input.pressed(key: .one)` for a game's first slot.
    public static func pressed(key: Key) -> Bool { keysNow.contains(key) && !keysBefore.contains(key) }

    /// True only on the update when the key goes up.
    public static func released(key: Key) -> Bool { !keysNow.contains(key) && keysBefore.contains(key) }

    /// Where the mouse is over the game, or the finger that's the pointer, in canvas pixels from the top-left corner;
    /// nil when there's none. Dragged past the canvas's edge, it stays on the edge until it lets go. Add the scene's
    /// `camera` for world pixels: `if Input.pressed(.pointer), let point = Input.pointer, chest.contains(point + camera)`.
    public private(set) static var pointer: Vector?

    /// Where the player's pushing, no longer than 1, y going down: a controller's left stick, from nothing at the edge of
    /// its dead zone to 1 at its rim, or else the D-pad's buttons, from the keys, a controller and the touch controls, 1
    /// long whichever way, diagonals too; zero when nothing's pushed. `velocity = Input.direction * 60` goes 60 pixels a
    /// second every way, where the D-pad's buttons alone go faster diagonally.
    public private(set) static var direction = Vector.zero

    /// What the player's using, by what last pressed a button or moved the pointer, for a hint that names a button, as
    /// "C swings" on a keyboard and "X swings" on a controller do. It starts as touch on iOS and the keyboard on a Mac.
    public private(set) static var using = Device.standard

    /// Where the touch controls are, in canvas pixels, the D-pad's and the buttons', those parts of them over the canvas,
    /// while they show: what a game keeps clear of, like a card or a choice near a bottom corner. Empty without them,
    /// as on a Mac, or with the screen upright, where they're below the game.
    public internal(set) static var touchControls: [Rect] = []

    /// Whether the touch controls stand aside, for a window that takes taps all over the canvas, as an inventory's grid
    /// does: while it's true they don't show, `touchControls` is empty, and every finger is the pointer. A game sets it
    /// as such a window opens and clears it as it closes, and the controls come back as they were.
    public static var touchControlsAside = false

    /// What a player plays with, for `Input.using`.
    public enum Device: Sendable {
        /// A keyboard, and the mouse with it.
        case keyboard
        /// A game controller.
        case controller
        /// The touch controls, or a finger on the game.
        case touch

        #if os(iOS)
        static let standard = Device.touch
        #else
        static let standard = Device.keyboard
        #endif
    }

    /// A key on a Mac's keyboard or an iPad's, for `held(key:)` and the others: its letters, digits, Escape, Tab, Shift,
    /// Space, Return, Delete and the arrows, by the key's place on a US keyboard.
    public enum Key: Sendable, CaseIterable {
        /// A letter.
        case a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z
        /// A digit, on the row above the letters.
        case zero, one, two, three, four, five, six, seven, eight, nine
        /// Escape, which also presses Start.
        case escape
        /// Tab.
        case tab
        /// Either Shift.
        case shift
        /// The space bar, which also presses A.
        case space
        /// Return, which also presses Start.
        case `return`
        /// Delete, back a character.
        case delete
        /// An arrow key, which also presses the D-pad's button.
        case left, right, up, down
    }

    static var now: Set<Button> = []
    static var before: Set<Button> = []
    static var keysNow: Set<Key> = []
    static var keysBefore: Set<Key> = []

    static var canvas = Size(320, 180) // the game's resolution, from its loop
    static var mouse: Vector? // the pointer as its last event left it
    static var down = false // held on the canvas, or dragged off it
    static var click: Vector? // where it went down, until an update sees it, so a click between two updates counts
    static var pad: Set<Button> = [] // a controller's, as the last update read them
    static var pushed: Set<Button> = [] // its buttons that went down since, which its handler hears, so a tap counts
    static weak var heard: GCExtendedGamepad? // the controller whose handler that is
    static var stickPushed = false // its stick past the dead zone, at the last update

    #if os(macOS)
    /// Key codes held right now, fed by GameView or the editor's preview.
    static var keys: Set<Int> = [] {
        didSet {
            let new = keys.subtracting(oldValue)
            struck.formUnion(new)
            if !new.isEmpty { using = .keyboard }
        }
    }
    static var struck: Set<Int> = [] // gone down since the last update, so a key tapped between two counts

    static let keyMap: [Int: Button] = [
        kVK_LeftArrow: .left, kVK_ANSI_A: .left, kVK_RightArrow: .right, kVK_ANSI_D: .right,
        kVK_UpArrow: .up, kVK_ANSI_W: .up, kVK_DownArrow: .down, kVK_ANSI_S: .down,
        kVK_ANSI_Z: .a, kVK_Space: .a, kVK_ANSI_X: .b, kVK_ANSI_C: .x, kVK_ANSI_V: .y, kVK_Return: .start, kVK_Escape: .start,
    ]

    static let keyNames: [Int: Key] = [
        kVK_ANSI_A: .a, kVK_ANSI_B: .b, kVK_ANSI_C: .c, kVK_ANSI_D: .d, kVK_ANSI_E: .e, kVK_ANSI_F: .f, kVK_ANSI_G: .g,
        kVK_ANSI_H: .h, kVK_ANSI_I: .i, kVK_ANSI_J: .j, kVK_ANSI_K: .k, kVK_ANSI_L: .l, kVK_ANSI_M: .m, kVK_ANSI_N: .n,
        kVK_ANSI_O: .o, kVK_ANSI_P: .p, kVK_ANSI_Q: .q, kVK_ANSI_R: .r, kVK_ANSI_S: .s, kVK_ANSI_T: .t, kVK_ANSI_U: .u,
        kVK_ANSI_V: .v, kVK_ANSI_W: .w, kVK_ANSI_X: .x, kVK_ANSI_Y: .y, kVK_ANSI_Z: .z,
        kVK_ANSI_0: .zero, kVK_ANSI_1: .one, kVK_ANSI_2: .two, kVK_ANSI_3: .three, kVK_ANSI_4: .four,
        kVK_ANSI_5: .five, kVK_ANSI_6: .six, kVK_ANSI_7: .seven, kVK_ANSI_8: .eight, kVK_ANSI_9: .nine,
        kVK_Escape: .escape, kVK_Tab: .tab, kVK_Shift: .shift, kVK_RightShift: .shift, kVK_Space: .space, kVK_Return: .return,
        kVK_Delete: .delete, kVK_LeftArrow: .left, kVK_RightArrow: .right, kVK_UpArrow: .up, kVK_DownArrow: .down,
    ]

    /// Each Shift's bit in a key event's modifier flags, the left's and the right's apart (NX_DEVICELSHIFTKEYMASK and
    /// NX_DEVICERSHIFTKEYMASK), since they come as a change of the flags rather than as keys going down.
    static let shiftBits: [Int: UInt] = [kVK_Shift: 0x2, kVK_RightShift: 0x4]
    #else
    /// Held on the touch controls.
    static var touched: Set<Button> = [] {
        didSet {
            let new = touched.subtracting(oldValue)
            tapped.formUnion(new)
            if !new.isEmpty { using = .touch }
        }
    }
    static var tapped: Set<Button> = [] // gone down on them since the last update, so a tap between two counts
    /// Held on a keyboard, fed by GameViewController.
    static var keys: Set<GCKeyCode> = [] {
        didSet {
            let new = keys.subtracting(oldValue)
            struck.formUnion(new)
            if !new.isEmpty { using = .keyboard }
        }
    }
    static var struck: Set<GCKeyCode> = [] // gone down since the last update
    static var hardware = false // a keyboard or controller held something in the last update, so the touch controls hide

    static let keyMap: [GCKeyCode: Button] = [ // an iPad's keyboard, or the Mac's in the editor's preview
        .leftArrow: .left, .keyA: .left, .rightArrow: .right, .keyD: .right, .upArrow: .up, .keyW: .up,
        .downArrow: .down, .keyS: .down, .keyZ: .a, .spacebar: .a, .keyX: .b, .keyC: .x, .keyV: .y, .returnOrEnter: .start,
        .escape: .start,
    ]

    static let keyNames: [GCKeyCode: Key] = [
        .keyA: .a, .keyB: .b, .keyC: .c, .keyD: .d, .keyE: .e, .keyF: .f, .keyG: .g, .keyH: .h, .keyI: .i, .keyJ: .j,
        .keyK: .k, .keyL: .l, .keyM: .m, .keyN: .n, .keyO: .o, .keyP: .p, .keyQ: .q, .keyR: .r, .keyS: .s, .keyT: .t,
        .keyU: .u, .keyV: .v, .keyW: .w, .keyX: .x, .keyY: .y, .keyZ: .z,
        .zero: .zero, .one: .one, .two: .two, .three: .three, .four: .four, .five: .five, .six: .six, .seven: .seven,
        .eight: .eight, .nine: .nine,
        .escape: .escape, .tab: .tab, .leftShift: .shift, .rightShift: .shift, .spacebar: .space, .returnOrEnter: .return,
        .deleteOrBackspace: .delete, .leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down,
    ]
    #endif

    /// The mouse or the pointer's finger at `pixel`, which may be off the canvas, with its button or the finger `down`,
    /// or nil once it's gone. It's held while down on the canvas, and a drag off it stays held, on its edge.
    static func point(_ pixel: Vector?, down isDown: Bool) {
        let edge: Vector = [Double(canvas.width - 1), Double(canvas.height - 1)]
        let inside = pixel.map { all($0 .>= Vector.zero .& $0 .<= edge) } ?? false
        if isDown, !down, inside { click = pixel }
        down = isDown && pixel != nil && (down || inside)
        mouse = down ? pixel?.clamped(lowerBound: .zero, upperBound: edge) : inside ? pixel : nil
        #if os(iOS)
        if pixel != nil { using = .touch }
        #else
        if pixel != nil { using = .keyboard }
        #endif
    }

    /// Runs before each update. What went down since the last one counts as pressed now, though it's up again: a key,
    /// a touch control and a controller's button tapped between two updates (1/60 s), as a click (`click`) does.
    static func poll() {
        before = now
        keysBefore = keysNow
        var held: Set<Button> = [], stick = Vector.zero // a game controller's
        if let gamepad = GCController.current?.extendedGamepad {
            hear(gamepad)
            held = buttons(of: gamepad)
            stick = [Double(gamepad.leftThumbstick.xAxis.value), -Double(gamepad.leftThumbstick.yAxis.value)]
        }
        let stickNow = length(stick) > deadZone
        if !held.subtracting(pad).isEmpty || !pushed.isEmpty || stickNow && !stickPushed { using = .controller }
        (pad, stickPushed) = (held, stickNow)
        held.formUnion(pushed)
        pushed = []
        let typed = keys.union(struck)
        struck = []
        keysNow = Set(typed.compactMap { keyNames[$0] })
        #if os(macOS)
        now = held.union(typed.compactMap { keyMap[$0] })
        #else
        hardware = !keys.isEmpty || !pad.isEmpty
        now = held.union(touched).union(tapped).union(typed.compactMap { keyMap[$0] })
        tapped = []
        #endif
        pointer = click ?? mouse
        if down || click != nil { now.insert(.pointer) }
        click = nil
        direction = Self.direction(stick: stick, buttons: now)
    }

    /// How far a stick goes before it counts as pushed, of the way to its rim.
    nonisolated static let deadZone = 0.2

    /// Where the player's pushing: `stick` past the dead zone, from nothing there to 1 at its rim, or else the D-pad's
    /// `buttons`, 1 long whichever way.
    nonisolated static func direction(stick: Vector, buttons: Set<Button>) -> Vector {
        let far = length(stick)
        if far > deadZone { return stick / far * min((far - deadZone) / (1 - deadZone), 1) }
        let way: Vector = [(buttons.contains(.right) ? 1 : 0) - (buttons.contains(.left) ? 1 : 0),
                           (buttons.contains(.down) ? 1 : 0) - (buttons.contains(.up) ? 1 : 0)]
        return way == .zero ? .zero : way / length(way)
    }

    nonisolated static func length(_ vector: Vector) -> Double { (vector * vector).sum().squareRoot() }

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
