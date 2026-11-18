import SwiftUI
import UIKit
import RGPCore

/// Optional on-screen controller drawn over the game: two sticks, D-pad, the four face buttons,
/// shoulders, triggers and the small buttons. Built on UIKit touches (not SwiftUI gestures) so
/// several fingers work at once and input is not delayed by gesture recognition.
struct TouchControlsView: UIViewRepresentable {
    /// Called on the main thread every time the on-screen state changes.
    let onChange: (ControllerState) -> Void
    /// A tap that did not land on any control (used to show or hide the top bar).
    let onBackgroundTap: () -> Void

    func makeUIView(context: Context) -> TouchPadView {
        let view = TouchPadView()
        view.onChange = onChange
        view.onBackgroundTap = onBackgroundTap
        return view
    }

    func updateUIView(_ view: TouchPadView, context: Context) {
        view.onChange = onChange
        view.onBackgroundTap = onBackgroundTap
    }

    static func dismantleUIView(_ view: TouchPadView, coordinator: ()) {
        view.onChange?(.neutral)      // never leave a button held when the controls go away
    }
}

final class TouchPadView: UIView {
    var onChange: ((ControllerState) -> Void)?
    var onBackgroundTap: (() -> Void)?

    private enum Control: Hashable {
        case leftStick, rightStick, dpad
        case button(UInt32)       // ControllerButtons raw value
        case l2, r2
    }

    private struct Spot {
        let control: Control
        var center: CGPoint
        var radius: CGFloat
        var label: String
    }

    private var spots: [Spot] = []
    private var touches: [UITouch: Control] = [:]
    private var backgroundTouches: [UITouch: CGPoint] = [:]
    private var leftVector = CGPoint.zero, rightVector = CGPoint.zero
    private var dpadVector = CGPoint.zero
    private var state = ControllerState.neutral
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        accessibilityIdentifier = "touchControls"
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let landscape = w > h
        // In portrait the picture sits in the middle of the screen, so the controls use the
        // lower half. In landscape they use the whole screen.
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            landscape ? CGPoint(x: fx * w, y: fy * h) : CGPoint(x: fx * w, y: h * 0.52 + fy * h * 0.46)
        }
        let unit = landscape ? h : min(w * 0.85, h * 0.42)
        let stick = unit * 0.15, big = unit * 0.075, small = unit * 0.052
        func x(_ f: CGFloat) -> CGFloat { f }
        // Portrait is narrower, so the outer clusters sit further in and the small row spreads out.
        let faceX: CGFloat = landscape ? 0.875 : 0.80, dpadX: CGFloat = landscape ? 0.125 : 0.19
        let stickY: CGFloat = landscape ? 0.78 : 0.70, smallY: CGFloat = landscape ? 0.90 : 0.96
        let smallStep: CGFloat = landscape ? 0.05 : 0.09

        let face = at(faceX, landscape ? 0.54 : 0.36), gap = unit * 0.125
        // Shoulders sit below the top bar so they never cover Disconnect or the status pills.
        spots = [
            Spot(control: .l2, center: at(x(0.09), landscape ? 0.25 : 0.06), radius: big * 0.9, label: "L2"),
            Spot(control: .button(ControllerButtons.l1.rawValue), center: at(x(0.24), landscape ? 0.25 : 0.06), radius: big * 0.9, label: "L1"),
            Spot(control: .button(ControllerButtons.r1.rawValue), center: at(x(0.76), landscape ? 0.25 : 0.06), radius: big * 0.9, label: "R1"),
            Spot(control: .r2, center: at(x(0.91), landscape ? 0.25 : 0.06), radius: big * 0.9, label: "R2"),

            Spot(control: .dpad, center: at(dpadX, landscape ? 0.54 : 0.36), radius: unit * 0.13, label: ""),
            Spot(control: .leftStick, center: at(x(0.29), stickY), radius: stick, label: "L"),
            Spot(control: .rightStick, center: at(x(0.71), stickY), radius: stick, label: "R"),

            Spot(control: .button(ControllerButtons.triangle.rawValue), center: CGPoint(x: face.x, y: face.y - gap), radius: big, label: "△"),
            Spot(control: .button(ControllerButtons.cross.rawValue), center: CGPoint(x: face.x, y: face.y + gap), radius: big, label: "✕"),
            Spot(control: .button(ControllerButtons.square.rawValue), center: CGPoint(x: face.x - gap, y: face.y), radius: big, label: "□"),
            Spot(control: .button(ControllerButtons.circle.rawValue), center: CGPoint(x: face.x + gap, y: face.y), radius: big, label: "○"),

            Spot(control: .button(ControllerButtons.l3.rawValue), center: at(0.5 - 2 * smallStep, smallY), radius: small, label: "L3"),
            Spot(control: .button(ControllerButtons.create.rawValue), center: at(0.5 - smallStep, smallY), radius: small, label: "⧉"),
            Spot(control: .button(ControllerButtons.touchpadClick.rawValue), center: at(0.5, smallY), radius: small, label: "▭"),
            Spot(control: .button(ControllerButtons.options.rawValue), center: at(0.5 + smallStep, smallY), radius: small, label: "≡"),
            Spot(control: .button(ControllerButtons.r3.rawValue), center: at(0.5 + 2 * smallStep, smallY), radius: small, label: "R3"),
        ]
        setNeedsDisplay()
    }

    // MARK: Touches

    private func control(at point: CGPoint) -> Control? {
        var best: (Control, CGFloat)?
        for spot in spots {
            let reach: CGFloat
            switch spot.control {
            case .leftStick, .rightStick: reach = spot.radius * 1.5
            case .dpad: reach = spot.radius * 1.25
            default: reach = spot.radius * 1.35
            }
            let d = hypot(point.x - spot.center.x, point.y - spot.center.y)
            if d <= reach, d < (best?.1 ?? .greatestFiniteMagnitude) { best = (spot.control, d) }
        }
        return best?.0
    }

    private func spot(_ control: Control) -> Spot? { spots.first { $0.control == control } }

    override func touchesBegan(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            let p = touch.location(in: self)
            if let c = control(at: p) {
                // One finger per stick; a second finger on the same stick is ignored.
                if (c == .leftStick || c == .rightStick), touches.values.contains(c) { continue }
                touches[touch] = c
                haptic.impactOccurred(intensity: 0.6)
            } else {
                backgroundTouches[touch] = p
            }
        }
        recompute()
    }

    override func touchesMoved(_ set: Set<UITouch>, with event: UIEvent?) {
        for touch in set {
            guard let current = touches[touch] else { continue }
            // Sticks and the D-pad keep their finger; a finger on a button may slide to another.
            if case .button = current, let now = control(at: touch.location(in: self)), now != current {
                if case .button = now { touches[touch] = now; haptic.impactOccurred(intensity: 0.4) }
            }
        }
        recompute()
    }

    override func touchesEnded(_ set: Set<UITouch>, with event: UIEvent?) { end(set, tapped: true) }
    override func touchesCancelled(_ set: Set<UITouch>, with event: UIEvent?) { end(set, tapped: false) }

    private func end(_ set: Set<UITouch>, tapped: Bool) {
        for touch in set {
            touches[touch] = nil
            if let start = backgroundTouches.removeValue(forKey: touch), tapped {
                let p = touch.location(in: self)
                if hypot(p.x - start.x, p.y - start.y) < 12 { onBackgroundTap?() }
            }
        }
        recompute()
    }

    private func recompute() {
        var next = ControllerState()
        leftVector = .zero; rightVector = .zero; dpadVector = .zero
        for (touch, control) in touches {
            guard let s = spot(control) else { continue }
            let p = touch.location(in: self)
            var v = CGPoint(x: (p.x - s.center.x) / s.radius, y: (p.y - s.center.y) / s.radius)
            let m = hypot(v.x, v.y)
            if m > 1 { v.x /= m; v.y /= m }
            switch control {
            case .leftStick: leftVector = v; next.leftX = Float(v.x); next.leftY = Float(-v.y)
            case .rightStick: rightVector = v; next.rightX = Float(v.x); next.rightY = Float(-v.y)
            case .dpad:
                dpadVector = v
                if v.x < -0.33 { next.buttons.insert(.dpadLeft) }
                if v.x > 0.33 { next.buttons.insert(.dpadRight) }
                if v.y < -0.33 { next.buttons.insert(.dpadUp) }
                if v.y > 0.33 { next.buttons.insert(.dpadDown) }
            case .button(let raw): next.buttons.insert(ControllerButtons(rawValue: raw))
            case .l2: next.l2 = 1
            case .r2: next.r2 = 1
            }
        }
        setNeedsDisplay()
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let line = UIColor.white.withAlphaComponent(0.55)
        let fill = UIColor.white.withAlphaComponent(0.10)
        let active = UIColor.white.withAlphaComponent(0.45)
        let held = Set(touches.values)

        for s in spots {
            let box = CGRect(x: s.center.x - s.radius, y: s.center.y - s.radius, width: s.radius * 2, height: s.radius * 2)
            switch s.control {
            case .leftStick, .rightStick:
                ctx.setFillColor(fill.cgColor); ctx.fillEllipse(in: box)
                ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: box)
                let v = s.control == .leftStick ? leftVector : rightVector
                let k = s.radius * 0.5
                let knob = CGRect(x: s.center.x + v.x * s.radius * 0.6 - k, y: s.center.y + v.y * s.radius * 0.6 - k, width: k * 2, height: k * 2)
                ctx.setFillColor((held.contains(s.control) ? active : UIColor.white.withAlphaComponent(0.28)).cgColor)
                ctx.fillEllipse(in: knob)
            case .dpad:
                let arm = s.radius * 0.36
                let cross = UIBezierPath()
                cross.append(UIBezierPath(roundedRect: CGRect(x: s.center.x - arm, y: s.center.y - s.radius, width: arm * 2, height: s.radius * 2), cornerRadius: arm * 0.4))
                cross.append(UIBezierPath(roundedRect: CGRect(x: s.center.x - s.radius, y: s.center.y - arm, width: s.radius * 2, height: arm * 2), cornerRadius: arm * 0.4))
                fill.setFill(); cross.fill()
                line.setStroke(); cross.lineWidth = 1.5; cross.stroke()
                if held.contains(.dpad) {
                    let d = s.radius * 0.62
                    var marks: [CGPoint] = []
                    if dpadVector.x < -0.33 { marks.append(CGPoint(x: -d, y: 0)) }
                    if dpadVector.x > 0.33 { marks.append(CGPoint(x: d, y: 0)) }
                    if dpadVector.y < -0.33 { marks.append(CGPoint(x: 0, y: -d)) }
                    if dpadVector.y > 0.33 { marks.append(CGPoint(x: 0, y: d)) }
                    ctx.setFillColor(active.cgColor)
                    for m in marks { ctx.fillEllipse(in: CGRect(x: s.center.x + m.x - arm * 0.8, y: s.center.y + m.y - arm * 0.8, width: arm * 1.6, height: arm * 1.6)) }
                }
            default:
                ctx.setFillColor((held.contains(s.control) ? active : fill).cgColor); ctx.fillEllipse(in: box)
                ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: box)
            }
            if !s.label.isEmpty, s.control != .leftStick, s.control != .rightStick {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: s.radius * 0.78, weight: .bold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                ]
                let size = (s.label as NSString).size(withAttributes: attrs)
                (s.label as NSString).draw(at: CGPoint(x: s.center.x - size.width / 2, y: s.center.y - size.height / 2), withAttributes: attrs)
            }
        }
    }
}
