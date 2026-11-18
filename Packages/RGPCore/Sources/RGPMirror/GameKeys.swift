import Foundation
import RGPCore

/// "Game keys" mode for computer sessions: turns a controller into the keyboard keys and mouse
/// a PC player would use, because a Mac cannot be given a pretend gamepad without a special
/// Apple entitlement. Plain logic here so it can be tested; the host app does the pressing.
public struct GameKeyState: Equatable, Sendable {
    /// macOS virtual key codes currently held.
    public var keys: Set<UInt16> = []
    public var leftMouse = false
    public var rightMouse = false
    /// Mouse-look speed, -1…1 on each axis (x right-positive, y up-positive).
    public var lookX: Float = 0
    public var lookY: Float = 0
    public init() {}
}

public enum GameKeys {
    public enum Key {
        public static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        public static let space: UInt16 = 49, c: UInt16 = 8, r: UInt16 = 15, f: UInt16 = 3
        public static let e: UInt16 = 14, q: UInt16 = 12, shift: UInt16 = 56, v: UInt16 = 9
        public static let escape: UInt16 = 53, tab: UInt16 = 48, m: UInt16 = 46
        public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    /// How far a stick must be pushed before it counts as a key press or a look.
    public static let moveThreshold: Float = 0.35
    public static let lookDeadZone: Float = 0.12
    public static let triggerThreshold: Float = 0.3

    private static let buttonKeys: [(ControllerButtons, UInt16)] = [
        (.cross, Key.space), (.circle, Key.c), (.square, Key.r), (.triangle, Key.f),
        (.r1, Key.e), (.l1, Key.q), (.l3, Key.shift), (.r3, Key.v),
        (.options, Key.escape), (.create, Key.tab), (.touchpadClick, Key.m),
        (.dpadLeft, Key.left), (.dpadRight, Key.right), (.dpadDown, Key.down), (.dpadUp, Key.up),
    ]

    public static func state(for c: ControllerState) -> GameKeyState {
        var out = GameKeyState()
        if c.leftY > moveThreshold { out.keys.insert(Key.w) }
        if c.leftY < -moveThreshold { out.keys.insert(Key.s) }
        if c.leftX < -moveThreshold { out.keys.insert(Key.a) }
        if c.leftX > moveThreshold { out.keys.insert(Key.d) }
        for (button, key) in buttonKeys where c.buttons.contains(button) { out.keys.insert(key) }
        out.leftMouse = c.r2 > triggerThreshold
        out.rightMouse = c.l2 > triggerThreshold
        out.lookX = abs(c.rightX) > lookDeadZone ? c.rightX : 0
        out.lookY = abs(c.rightY) > lookDeadZone ? c.rightY : 0
        return out
    }

    /// Shown in the host window and the docs so people know what each control sends.
    public static let legend: [(control: String, sends: String)] = [
        ("Left stick", "W A S D (move)"),
        ("Right stick", "Mouse (look)"),
        ("R2", "Left mouse button"),
        ("L2", "Right mouse button"),
        ("Cross", "Space"), ("Circle", "C"), ("Square", "R"), ("Triangle", "F"),
        ("R1", "E"), ("L1", "Q"), ("L3", "Shift"), ("R3", "V"),
        ("D-pad", "Arrow keys"),
        ("Options", "Escape"), ("Create", "Tab"), ("Touchpad click", "M"),
    ]
}
