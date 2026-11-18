import Foundation

// MARK: - C. Input contracts

public struct ControllerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let cross     = ControllerButtons(rawValue: 1 << 0)
    public static let circle    = ControllerButtons(rawValue: 1 << 1)
    public static let square    = ControllerButtons(rawValue: 1 << 2)
    public static let triangle  = ControllerButtons(rawValue: 1 << 3)
    public static let dpadUp    = ControllerButtons(rawValue: 1 << 4)
    public static let dpadDown  = ControllerButtons(rawValue: 1 << 5)
    public static let dpadLeft  = ControllerButtons(rawValue: 1 << 6)
    public static let dpadRight = ControllerButtons(rawValue: 1 << 7)
    public static let l1        = ControllerButtons(rawValue: 1 << 8)
    public static let r1        = ControllerButtons(rawValue: 1 << 9)
    public static let l3        = ControllerButtons(rawValue: 1 << 10)
    public static let r3        = ControllerButtons(rawValue: 1 << 11)
    public static let options   = ControllerButtons(rawValue: 1 << 12)
    public static let create    = ControllerButtons(rawValue: 1 << 13)
    public static let ps        = ControllerButtons(rawValue: 1 << 14)
    public static let touchpadClick = ControllerButtons(rawValue: 1 << 15)

    public static let labelled: [(ControllerButtons, String)] = [
        (.cross, "Cross"), (.circle, "Circle"), (.square, "Square"), (.triangle, "Triangle"),
        (.dpadUp, "D-pad Up"), (.dpadDown, "D-pad Down"), (.dpadLeft, "D-pad Left"), (.dpadRight, "D-pad Right"),
        (.l1, "L1"), (.r1, "R1"), (.l3, "L3"), (.r3, "R3"),
        (.options, "Options"), (.create, "Create"), (.ps, "PS"), (.touchpadClick, "Touchpad click"),
    ]
}

/// One snapshot of the player's controller, in console-neutral form.
/// Sticks are -1...1 (x right-positive, y up-positive); triggers are 0...1.
public struct ControllerState: Sendable, Equatable {
    public var buttons: ControllerButtons = []
    public var leftX: Float = 0, leftY: Float = 0
    public var rightX: Float = 0, rightY: Float = 0
    public var l2: Float = 0, r2: Float = 0
    public init() {}
    public static let neutral = ControllerState()
}

/// A person's own button layout: "when I press this, send that". Buttons not listed send
/// themselves. Applied to the physical controller only; on-screen controls are already labelled.
public struct ButtonMapping: Codable, Equatable, Sendable {
    /// Pressed button (raw value) → button sent to the console (raw value).
    public var buttons: [UInt32: UInt32] = [:]
    public var swapSticks = false
    public var invertLeftY = false
    public var invertRightY = false
    public init() {}
    public static let `default` = ButtonMapping()
    public var isDefault: Bool { self == .default }

    /// The PS button is left out: iOS keeps it, and the app sends it from its own on-screen button.
    public static let remappable: [(ControllerButtons, String)] = ControllerButtons.labelled.filter { $0.0 != .ps }

    public func target(for button: ControllerButtons) -> ControllerButtons {
        buttons[button.rawValue].map { ControllerButtons(rawValue: $0) } ?? button
    }

    public mutating func set(_ button: ControllerButtons, to target: ControllerButtons) {
        if target == button { buttons[button.rawValue] = nil } else { buttons[button.rawValue] = target.rawValue }
    }

    public func apply(_ state: ControllerState) -> ControllerState {
        if isDefault { return state }
        var out = state
        var mapped: ControllerButtons = []
        for (button, _) in ControllerButtons.labelled where state.buttons.contains(button) {
            mapped.insert(target(for: button))
        }
        out.buttons = mapped
        if swapSticks {
            out.leftX = state.rightX; out.leftY = state.rightY
            out.rightX = state.leftX; out.rightY = state.leftY
        }
        if invertLeftY { out.leftY = -out.leftY }
        if invertRightY { out.rightY = -out.rightY }
        return out
    }

    /// Two different buttons set to send the same thing. Allowed, but worth pointing out.
    public var duplicateTargets: [ControllerButtons] {
        var seen: [UInt32: Int] = [:]
        for (button, _) in Self.remappable { seen[target(for: button).rawValue, default: 0] += 1 }
        return seen.filter { $0.value > 1 }.map { ControllerButtons(rawValue: $0.key) }
    }
}

/// Keys the on-screen keyboard can send besides text (computer sessions only).
public enum SpecialKey: UInt8, Sendable, CaseIterable {
    case returnKey = 1, delete, escape, tab, up, down, left, right
}

public enum InputMapper {
    /// Radial dead zone with rescale so output still reaches 1.0 at full deflection.
    public static func applyDeadZone(x: Float, y: Float, deadZone: Float = 0.08) -> (x: Float, y: Float) {
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > deadZone, magnitude > 0 else { return (0, 0) }
        let scaled = min(1, (magnitude - deadZone) / (1 - deadZone))
        return (x / magnitude * scaled, y / magnitude * scaled)
    }

    public static func normalized(_ state: ControllerState, deadZone: Float = 0.08) -> ControllerState {
        var out = state
        (out.leftX, out.leftY) = applyDeadZone(x: state.leftX, y: state.leftY, deadZone: deadZone)
        (out.rightX, out.rightY) = applyDeadZone(x: state.rightX, y: state.rightY, deadZone: deadZone)
        out.l2 = min(1, max(0, state.l2)); out.r2 = min(1, max(0, state.r2))
        return out
    }
}

public struct ControllerInfo: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isExtendedLayout: Bool   // has both sticks and triggers
    /// The family the system reports ("DualSense", "Xbox One", "Switch Pro Controller", "MFi"…).
    public var category: String
    public init(id: String, name: String, isExtendedLayout: Bool, category: String = "") {
        self.id = id; self.name = name; self.isExtendedLayout = isExtendedLayout; self.category = category
    }
    public var support: ControllerSupport { ControllerSupport.status(category: category, name: name) }
}

/// What we can honestly say about a controller. Only "tested" means we have seen it work with a
/// real console; everything else is what the phone's own controller support should give.
public enum ControllerSupport: Equatable, Sendable {
    /// Confirmed by us on a real console.
    case tested(note: String)
    /// A standard full-layout controller the phone supports. Buttons and sticks should work the
    /// same way; nobody here has tried it yet.
    case expected(note: String)
    case unknown

    public var title: String {
        switch self {
        case .tested: return "Tested with a real console"
        case .expected: return "Should work. Not tested by us yet"
        case .unknown: return "Unknown controller. Try the button test below"
        }
    }
    public var note: String {
        switch self {
        case .tested(let note), .expected(let note): return note
        case .unknown: return "If the buttons and sticks light up in the test below, it will work in games. Please tell us the result."
        }
    }

    /// The list of what has really been tested. Add a line only after a real-console check.
    public static func status(category: String, name: String) -> ControllerSupport {
        let text = (category + " " + name).lowercased()
        if text.contains("dualsense") {
            return .tested(note: "DualSense: confirmed by cable and by Bluetooth.")
        }
        if text.contains("dualshock") {
            return .expected(note: "PlayStation 4 controller. Same layout as the DualSense.")
        }
        if text.contains("xbox") {
            return .expected(note: "Xbox controller. A sends Cross, B Circle, X Square, Y Triangle; Menu is Options and View is Create. There is no touchpad button.")
        }
        if text.contains("switch") || text.contains("joy-con") || text.contains("nintendo") {
            return .expected(note: "Nintendo controller. Buttons are matched by position, so the bottom button sends Cross whatever its letter. There is no touchpad button.")
        }
        if text.contains("mfi") || text.contains("backbone") || text.contains("razer") || text.contains("8bitdo") || text.contains("gamesir") || text.contains("steelseries") {
            return .expected(note: "A phone game controller. Buttons are matched by position. There is no touchpad button.")
        }
        return .unknown
    }
}

/// Honest feature list shown on the controller screen.
public struct ControllerFeature: Identifiable, Sendable {
    public enum Support: String, Sendable { case supported = "Read by the app", notYet = "Not supported yet" }
    public var id: String { name }
    public var name: String
    public var support: Support
    public var note: String

    public static let all: [ControllerFeature] = [
        .init(name: "Buttons, D-pad, sticks, triggers", support: .supported,
              note: "Read from the controller and shown in the test above. Confirmed reaching a real PlayStation 5 with a DualSense controller, by cable and by Bluetooth."),
        .init(name: "Haptic feedback / rumble", support: .notYet, note: "Needs console-to-controller data that the transport does not carry yet."),
        .init(name: "Adaptive triggers", support: .notYet, note: "Not implemented."),
        .init(name: "Touchpad gestures", support: .notYet, note: "Touchpad click is mapped; finger position is not."),
        .init(name: "Motion sensors", support: .notYet, note: "Not implemented."),
        .init(name: "Controller microphone / speaker", support: .notYet, note: "Not implemented."),
        .init(name: "On-screen touch controls", support: .supported, note: "Sticks, D-pad, face buttons, shoulders, triggers (full press only), L3/R3, Create, Options and touchpad click. Turn on with the hand button in the player."),
    ]
}
