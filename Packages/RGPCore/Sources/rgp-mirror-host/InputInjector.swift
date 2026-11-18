import Foundation
import CoreGraphics
import ApplicationServices
import RGPCore
import RGPMirror

/// Turns input from the phone into mouse and keyboard events on this Mac.
/// Needs the Accessibility permission; without it macOS silently ignores the events.
///
/// Touch: finger position = pointer position; touch down/up = left button; two-finger tap = right click.
/// Controller: left stick moves the pointer, right stick scrolls, Cross = click, Circle = right click,
/// D-pad = arrow keys, Triangle = Space, Square = Return, Options = Escape.
final class InputInjector {
    private let queue = DispatchQueue(label: "rgp.host.input")
    private var controller = ControllerState()
    private var timer: DispatchSourceTimer?
    private var leftDown = false

    /// How a controller drives this Mac. Desktop: pointer and clicks. Game keys: W-A-S-D, mouse
    /// look and the keys PC games use (see `GameKeys`).
    enum Mode: String { case desktop, gameKeys }
    private var mode = Mode.desktop
    private var game = GameKeyState()
    private var rightDown = false

    func setMode(_ new: Mode) {
        releaseAll()
        queue.async { self.mode = new }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func promptForPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// The display the phone is looking at. Set by the host whenever screen sharing (re)starts,
    /// so touches land on the shared screen even when another display is attached or removed.
    var displayID = CGMainDisplayID()
    private var bounds: CGRect { CGDisplayBounds(displayID) }

    private func currentPosition() -> CGPoint { CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY) }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func postKey(_ code: CGKeyCode, down: Bool) {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
    }

    /// Types text from the phone's keyboard, as if typed on this Mac.
    func handle(text: String) {
        queue.async {
            for character in text {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }

    func handle(key: SpecialKey) {
        let code: CGKeyCode
        switch key {
        case .returnKey: code = 36
        case .delete: code = 51
        case .escape: code = 53
        case .tab: code = 48
        case .up: code = 126
        case .down: code = 125
        case .left: code = 123
        case .right: code = 124
        }
        queue.async { self.postKey(code, down: true); self.postKey(code, down: false) }
    }

    func handle(pointer event: PointerEvent) {
        queue.async {
            let b = self.bounds
            let point = CGPoint(x: b.minX + CGFloat(event.x) * b.width, y: b.minY + CGFloat(event.y) * b.height)
            switch event.phase {
            case .move: self.postMouse(self.leftDown ? .leftMouseDragged : .mouseMoved, at: point)
            case .down: self.leftDown = true; self.postMouse(.leftMouseDown, at: point)
            case .up: self.leftDown = false; self.postMouse(.leftMouseUp, at: point)
            case .secondaryClick:
                self.postMouse(.rightMouseDown, at: point, button: .right)
                self.postMouse(.rightMouseUp, at: point, button: .right)
            }
        }
    }

    func handle(controller new: ControllerState) {
        queue.async {
            if self.mode == .gameKeys { self.applyGame(new); return }
            let old = self.controller
            self.controller = new
            let point = self.currentPosition()
            func edge(_ button: ControllerButtons, _ action: (Bool) -> Void) {
                let was = old.buttons.contains(button), now = new.buttons.contains(button)
                if was != now { action(now) }
            }
            edge(.cross) { down in
                self.leftDown = down
                self.postMouse(down ? .leftMouseDown : .leftMouseUp, at: point)
            }
            edge(.circle) { down in self.postMouse(down ? .rightMouseDown : .rightMouseUp, at: point, button: .right) }
            edge(.dpadLeft) { self.postKey(123, down: $0) }
            edge(.dpadRight) { self.postKey(124, down: $0) }
            edge(.dpadDown) { self.postKey(125, down: $0) }
            edge(.dpadUp) { self.postKey(126, down: $0) }
            edge(.triangle) { self.postKey(49, down: $0) }
            edge(.square) { self.postKey(36, down: $0) }
            edge(.options) { self.postKey(53, down: $0) }

            let moving = abs(new.leftX) > 0.01 || abs(new.leftY) > 0.01 || abs(new.rightY) > 0.01
            if moving, self.timer == nil { self.startTimer() }
            if !moving { self.timer?.cancel(); self.timer = nil }
        }
    }

    /// Game keys mode: press and release exactly what changed, and keep the mouse moving while
    /// the right stick is held.
    private func applyGame(_ new: ControllerState) {
        controller = new
        let next = GameKeys.state(for: new)
        for key in game.keys.subtracting(next.keys) { postKey(CGKeyCode(key), down: false) }
        for key in next.keys.subtracting(game.keys) { postKey(CGKeyCode(key), down: true) }
        let point = currentPosition()
        if next.leftMouse != game.leftMouse {
            leftDown = next.leftMouse
            postMouse(next.leftMouse ? .leftMouseDown : .leftMouseUp, at: point)
        }
        if next.rightMouse != game.rightMouse {
            rightDown = next.rightMouse
            postMouse(next.rightMouse ? .rightMouseDown : .rightMouseUp, at: point, button: .right)
        }
        game = next
        let looking = next.lookX != 0 || next.lookY != 0
        if looking, timer == nil { startLookTimer() }
        if !looking { timer?.cancel(); timer = nil }
    }

    private func startLookTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let speed: Float = 9
            let dx = Int64((self.game.lookX * speed).rounded()), dy = Int64((-self.game.lookY * speed).rounded())
            guard dx != 0 || dy != 0 else { return }
            let b = self.bounds
            var p = self.currentPosition()
            p.x = min(b.maxX - 1, max(b.minX, p.x + CGFloat(dx)))
            p.y = min(b.maxY - 1, max(b.minY, p.y + CGFloat(dy)))
            let type: CGEventType = self.leftDown ? .leftMouseDragged : self.rightDown ? .rightMouseDragged : .mouseMoved
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p,
                                      mouseButton: self.rightDown && !self.leftDown ? .right : .left) else { return }
            // Games that capture the pointer read these movement amounts, not the position.
            event.setIntegerValueField(.mouseEventDeltaX, value: dx)
            event.setIntegerValueField(.mouseEventDeltaY, value: dy)
            event.post(tap: .cghidEventTap)
        }
        timer.resume()
        self.timer = timer
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let s = self.controller
            if abs(s.leftX) > 0.01 || abs(s.leftY) > 0.01 {
                let b = self.bounds
                var p = self.currentPosition()
                let speed: CGFloat = 18
                p.x = min(b.maxX - 1, max(b.minX, p.x + CGFloat(s.leftX) * speed))
                p.y = min(b.maxY - 1, max(b.minY, p.y - CGFloat(s.leftY) * speed))   // stick up = pointer up
                self.postMouse(self.leftDown ? .leftMouseDragged : .mouseMoved, at: p)
            }
            if abs(s.rightY) > 0.01 {
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(s.rightY * 24), wheel2: 0, wheel3: 0)?
                    .post(tap: .cghidEventTap)
            }
        }
        timer.resume()
        self.timer = timer
    }

    /// Releases anything held, so a dropped connection cannot leave a button or key stuck.
    func releaseAll() {
        handle(controller: ControllerState())
        queue.async {
            for key in self.game.keys { self.postKey(CGKeyCode(key), down: false) }
            self.game = GameKeyState()
            self.timer?.cancel(); self.timer = nil
            if self.leftDown { self.leftDown = false; self.postMouse(.leftMouseUp, at: self.currentPosition()) }
            if self.rightDown { self.rightDown = false; self.postMouse(.rightMouseUp, at: self.currentPosition(), button: .right) }
        }
    }
}
