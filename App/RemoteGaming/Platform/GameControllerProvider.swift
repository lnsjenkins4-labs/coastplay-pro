import Foundation
import GameController
import RGPCore

/// Reads physical controllers through Apple's GameController framework and publishes a
/// console-neutral `ControllerState`. Handles connect/disconnect while the app is running.
@MainActor
final class GameControllerProvider: ObservableObject {
    @Published private(set) var controllers: [ControllerInfo] = []
    @Published private(set) var state = ControllerState.neutral
    var onInput: ((ControllerState) -> Void)?
    /// Called on the controller's own high-priority queue the moment input changes, so input
    /// does not wait behind interface drawing on the main thread. Set once, before controllers connect.
    nonisolated(unsafe) var onInputImmediate: (@Sendable (ControllerState) -> Void)?
    private let inputQueue = DispatchQueue(label: "rgp.controller-input", qos: .userInteractive)

    private var observers: [NSObjectProtocol] = []
    private var lastLogged = ""

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    var active: ControllerInfo? { controllers.first }

    private func refresh() {
        let all = GCController.controllers()
        controllers = all.enumerated().map { index, c in
            ControllerInfo(id: "\(index)-\(c.vendorName ?? "controller")", name: c.vendorName ?? "Controller",
                           isExtendedLayout: c.extendedGamepad != nil, category: c.productCategory)
        }
        // Keep a plain record of which controllers were used, so a compatibility report rests on
        // what really happened. Names only; nothing personal.
        let summary = controllers.map { "\($0.name) [\($0.category)]\($0.isExtendedLayout ? "" : ", limited layout")" }.joined(separator: "; ")
        if summary != lastLogged {
            lastLogged = summary
            ConnectionLog.shared.add(summary.isEmpty ? "Controller disconnected." : "Controller connected: \(summary).")
        }
        // Only the first controller drives input for now.
        for c in all { c.extendedGamepad?.valueChangedHandler = nil }
        if let first = all.first, let pad = first.extendedGamepad {
            first.handlerQueue = inputQueue
            pad.valueChangedHandler = { [weak self] pad, _ in
                let snapshot = Self.read(pad)
                self?.onInputImmediate?(snapshot)
                Task { @MainActor in self?.publish(snapshot) }
            }
        } else {
            onInputImmediate?(.neutral)   // controller gone: release everything so nothing stays held
            publish(.neutral)
        }
    }

    private func publish(_ new: ControllerState) {
        guard new != state else { return }
        state = new
        onInput?(new)
    }

    nonisolated private static func read(_ pad: GCExtendedGamepad) -> ControllerState {
        var s = ControllerState()
        var b: ControllerButtons = []
        if pad.buttonA.isPressed { b.insert(.cross) }
        if pad.buttonB.isPressed { b.insert(.circle) }
        if pad.buttonX.isPressed { b.insert(.square) }
        if pad.buttonY.isPressed { b.insert(.triangle) }
        if pad.dpad.up.isPressed { b.insert(.dpadUp) }
        if pad.dpad.down.isPressed { b.insert(.dpadDown) }
        if pad.dpad.left.isPressed { b.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { b.insert(.dpadRight) }
        if pad.leftShoulder.isPressed { b.insert(.l1) }
        if pad.rightShoulder.isPressed { b.insert(.r1) }
        if pad.leftThumbstickButton?.isPressed == true { b.insert(.l3) }
        if pad.rightThumbstickButton?.isPressed == true { b.insert(.r3) }
        if pad.buttonMenu.isPressed { b.insert(.options) }
        if pad.buttonOptions?.isPressed == true { b.insert(.create) }
        if pad.buttonHome?.isPressed == true { b.insert(.ps) }
        if let dual = pad as? GCDualSenseGamepad, dual.touchpadButton.isPressed { b.insert(.touchpadClick) }
        if let ds4 = pad as? GCDualShockGamepad, ds4.touchpadButton.isPressed { b.insert(.touchpadClick) }
        s.buttons = b
        s.leftX = pad.leftThumbstick.xAxis.value; s.leftY = pad.leftThumbstick.yAxis.value
        s.rightX = pad.rightThumbstick.xAxis.value; s.rightY = pad.rightThumbstick.yAxis.value
        s.l2 = pad.leftTrigger.value; s.r2 = pad.rightTrigger.value
        return s
    }
}
