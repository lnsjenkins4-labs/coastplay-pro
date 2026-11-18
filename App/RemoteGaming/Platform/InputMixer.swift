import Foundation
import RGPCore

/// Combines the physical controller and the on-screen controls into one state and passes it on.
/// Safe to call from any thread: the physical controller reports on its own queue and the
/// on-screen controls on the main thread.
final class InputMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var physical = ControllerState.neutral
    private var touch = ControllerState.neutral
    private var mapping = ButtonMapping.default
    private let output: @Sendable (ControllerState) -> Void

    init(output: @escaping @Sendable (ControllerState) -> Void) { self.output = output }

    /// The person's own layout. Applied to the physical controller only.
    func setMapping(_ new: ButtonMapping) { update { mapping = new } }
    func setPhysical(_ state: ControllerState) { update { physical = state } }
    func setTouch(_ state: ControllerState) { update { touch = state } }

    private func update(_ change: () -> Void) {
        lock.lock()
        change()
        let merged = Self.merge(mapping.apply(physical), touch)
        lock.unlock()
        output(merged)
    }

    /// Buttons from both; a stick or trigger comes from whichever one is being moved.
    static func merge(_ a: ControllerState, _ b: ControllerState) -> ControllerState {
        var out = a
        out.buttons.formUnion(b.buttons)
        if abs(b.leftX) > 0.01 || abs(b.leftY) > 0.01 { out.leftX = b.leftX; out.leftY = b.leftY }
        if abs(b.rightX) > 0.01 || abs(b.rightY) > 0.01 { out.rightX = b.rightX; out.rightY = b.rightY }
        out.l2 = max(a.l2, b.l2); out.r2 = max(a.r2, b.r2)
        return out
    }
}
