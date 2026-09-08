import AppKit

/// Small, clock-driven desk scenes in the renderer's 220-point coordinate space.
/// Agent adapters never select props or own animation timing.
enum WorkSceneRenderer {
    static func draw(_ c: CGContext, state: PetState, time: TimeInterval, body: CGColor) {
        let ink = CGColor(red: 0.16, green: 0.20, blue: 0.24, alpha: 1)
        let cream = CGColor(red: 0.98, green: 0.94, blue: 0.83, alpha: 1)
        let coral = CGColor(red: 0.94, green: 0.44, blue: 0.35, alpha: 1)
        let teal = CGColor(red: 0.27, green: 0.66, blue: 0.61, alpha: 1)
        let beat = CGFloat(sin(time * 9))
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor, _ r: CGFloat = 6) {
            c.setFillColor(color)
            c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
            c.fillPath()
        }
        func ball(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CGColor) {
            c.setFillColor(color)
            c.fillEllipse(in: CGRect(x: x-r, y: y-r, width: r*2, height: r*2))
        }
        func line(_ points: [CGPoint], _ color: CGColor, _ width: CGFloat = 3) {
            guard let first = points.first else { return }
            c.setStrokeColor(color); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
            c.move(to: first)
            for p in points.dropFirst() { c.addLine(to: p) }
            c.strokePath()
        }
        func stroke(_ x: CGFloat, _ y: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ color: CGColor, _ width: CGFloat = 3) {
            line([CGPoint(x: x, y: y), CGPoint(x: x2, y: y2)], color, width)
        }
        let bounce = state == .juggling ? beat * 2 : abs(beat) * 1.5
        // A soft body leans over the tools, with a focused downward gaze.
        c.saveGState()
        c.translateBy(x: state == .juggling ? -19 : 0, y: -12 + bounce)
        box(-43, -43, 86, 83, body, 35)
        box(-23, -15, 12, 22, cream, 6)
        box(11, -15, 12, 22, cream, 6)
        ball(-16, -1, 3, ink); ball(18, -1, 3, ink)
        c.restoreGState()

        switch state {
        case .typing:
            // Keyboard, alternating paws and individual illuminated key presses.
            box(-68, 36, 136, 33, ink, 9)
            box(-64, 36, 128, 27, cream, 7)
            let pressed = Int(time * 8) % 20
            for row in 0..<2 {
                for col in 0..<10 {
                    box(CGFloat(col)*12-58, CGFloat(row)*10+40, 9, 7,
                        row*10+col == pressed ? coral : teal, 2)
                }
            }
            box(-25, 60, 50, 4, teal, 2)
            stroke(-34, 13, -27, 33 + beat*3, body, 13)
            stroke(34, 13, 25, 33 - beat*3, body, 13)
            ball(-27, 33+beat*3, 9, body); ball(25, 33-beat*3, 9, body)
            // A tiny screen beside the face keeps the keyboard unobstructed.
            box(48, -43, 35, 31, ink, 5)
            box(52, -39, 27, 22, teal, 3)
            stroke(57, -32, 67, -32, cream, 2)
            stroke(57, -25, 72, -25, cream, 2)
            stroke(65, -12, 65, -5, ink, 4)
        case .building:
            // A sweater with sleeves, ribbing and moving crossed knitting needles.
            line([CGPoint(x:-25,y:30),CGPoint(x:-43,y:41),CGPoint(x:-36,y:54),CGPoint(x:-24,y:48),CGPoint(x:-24,y:72),CGPoint(x:24,y:72),CGPoint(x:24,y:48),CGPoint(x:36,y:54),CGPoint(x:43,y:41),CGPoint(x:25,y:30)], coral, 15)
            box(-25, 29, 50, 49, coral, 4)
            for x in stride(from: -18, through: 18, by: 9) {
                for y in stride(from: 39, through: 66, by: 9) {
                    stroke(CGFloat(x)-2, CGFloat(y), CGFloat(x), CGFloat(y)+3, cream, 1.5)
                    stroke(CGFloat(x), CGFloat(y)+3, CGFloat(x)+2, CGFloat(y), cream, 1.5)
                }
            }
            stroke(-37, 18+beat*3, 30, 40, ink, 3)
            stroke(37, 18-beat*3, -30, 40, ink, 3)
            ball(-32, 24+beat*3, 9, body); ball(32, 24-beat*3, 9, body)
            ball(64, 65, 17, coral)
            for offset in [-7.0, 0, 7] { stroke(54, 55+offset, 74, 67+offset, cream, 1.5) }
            line([CGPoint(x:52,y:72),CGPoint(x:40,y:78),CGPoint(x:29,y:64)], coral, 2)
        case .juggling:
            // Tractor wheels roll while the driver bobs and holds the steering wheel.
            box(-60, 29, 133, 32, teal, 8)
            box(15, 4, 61, 42, teal, 9)
            box(47, -13, 8, 21, ink, 3)
            box(64, 16, 14, 17, cream, 3)
            for x in [23.0, 31, 39] { stroke(x, 17, x, 31, ink, 2) }
            stroke(-10, 31, 6, 4, ink, 4)
            stroke(-4, -1, 16, 9, ink, 4)
            stroke(-29, 7, 1, 7+beat, body, 12)
            for (x, radius) in [(CGFloat(-40), CGFloat(26)), (CGFloat(53), CGFloat(19))] {
                ball(x, 59, radius, ink); ball(x, 59, radius*0.56, cream)
                for i in 0..<6 {
                    let angle = CGFloat(time*3) + CGFloat(i) * .pi / 3
                    stroke(x+cos(angle)*radius*0.7, 59+sin(angle)*radius*0.7,
                           x+cos(angle)*radius*0.89, 59+sin(angle)*radius*0.89, cream, 2)
                }
                ball(x, 59, 5, coral)
            }
            for i in 0..<3 {
                let phase = CGFloat((time*0.65+Double(i)/3).truncatingRemainder(dividingBy: 1))
                c.setAlpha(1-phase)
                ball(51+phase*13, -21-phase*25, 3+phase*4, cream)
            }
            c.setAlpha(1)
        default: break
        }
    }
}
