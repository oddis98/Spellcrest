#if os(macOS)
import Carbon.HIToolbox // kVK_ key codes

extension Input {
    /// The buttons and keys the Mac's keys are, by their key codes, which the window and the editor's preview send.
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
}
#elseif os(iOS)
import GameController

extension Input {
    /// The buttons and keys a keyboard's keys are, by their HID usages, as `GCKeyCode`s have them.
    static let keyMap = Dictionary(uniqueKeysWithValues: keyButtons.map { ($0.key.rawValue, $0.value) })
    static let keyNames = Dictionary(uniqueKeysWithValues: keyKeys.map { ($0.key.rawValue, $0.value) })

    private static let keyButtons: [GCKeyCode: Button] = [ // an iPad's keyboard, or the Mac's in a simulator
        .leftArrow: .left, .keyA: .left, .rightArrow: .right, .keyD: .right, .upArrow: .up, .keyW: .up,
        .downArrow: .down, .keyS: .down, .keyZ: .a, .spacebar: .a, .keyX: .b, .keyC: .x, .keyV: .y, .returnOrEnter: .start,
        .escape: .start,
    ]

    private static let keyKeys: [GCKeyCode: Key] = [
        .keyA: .a, .keyB: .b, .keyC: .c, .keyD: .d, .keyE: .e, .keyF: .f, .keyG: .g, .keyH: .h, .keyI: .i, .keyJ: .j,
        .keyK: .k, .keyL: .l, .keyM: .m, .keyN: .n, .keyO: .o, .keyP: .p, .keyQ: .q, .keyR: .r, .keyS: .s, .keyT: .t,
        .keyU: .u, .keyV: .v, .keyW: .w, .keyX: .x, .keyY: .y, .keyZ: .z,
        .zero: .zero, .one: .one, .two: .two, .three: .three, .four: .four, .five: .five, .six: .six, .seven: .seven,
        .eight: .eight, .nine: .nine,
        .escape: .escape, .tab: .tab, .leftShift: .shift, .rightShift: .shift, .spacebar: .space, .returnOrEnter: .return,
        .deleteOrBackspace: .delete, .leftArrow: .left, .rightArrow: .right, .upArrow: .up, .downArrow: .down,
    ]
}
#endif
