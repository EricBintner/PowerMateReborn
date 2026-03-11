import AppKit

struct MenuBarIcon {

    // Menu bar icons: 18x18 points (standard macOS menu bar size)
    // SVG source uses a 24x24 viewBox; scale factor = 0.75
    static let size = NSSize(width: 18, height: 18)
    private static let k: CGFloat = 18.0 / 24.0

    private static func s(_ v: CGFloat) -> CGFloat { v * k }
    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: s(x), y: s(y))
    }

    // MARK: - Public Icons

    /// Brightness mode: Lucide-style sun -- center circle + 8 short rays
    static func brightness() -> NSImage {
        makeIcon { ctx in
            drawKnobCircle(ctx)
            drawAllRays(ctx)
        }
    }

    /// Volume mode: sun-knob hybrid -- left rays + right-side sound arcs
    static func volume() -> NSImage {
        makeIcon { ctx in
            drawKnobCircle(ctx)
            drawLeftRays(ctx)
            drawSoundArcs(ctx)
        }
    }

    /// Custom mode: sun-dim style -- center circle + dot rays
    static func custom() -> NSImage {
        makeIcon { ctx in
            drawKnobCircle(ctx)
            drawDotRays(ctx)
        }
    }

    /// Disconnected: center circle + diagonal slash
    static func disconnected() -> NSImage {
        makeIcon { ctx in
            drawKnobCircle(ctx)
            addLine(ctx, x1: 5, y1: 5, x2: 19, y2: 19)
            ctx.strokePath()
        }
    }

    // MARK: - Icon Factory

    private static func makeIcon(_ draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.clear.cgColor)
            ctx.setLineWidth(s(2))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            draw(ctx)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Shape Components

    /// Center knob circle (r=4 in 24x24 SVG coords)
    private static func drawKnobCircle(_ ctx: CGContext) {
        let r: CGFloat = 4
        ctx.addEllipse(in: CGRect(
            x: s(12 - r), y: s(12 - r), width: s(r * 2), height: s(r * 2)
        ))
        ctx.strokePath()
    }

    /// All 8 rays (brightness mode) -- matches Lucide sun icon geometry
    private static func drawAllRays(_ ctx: CGContext) {
        addLine(ctx, x1: 12, y1: 2, x2: 12, y2: 4)                       // top
        addLine(ctx, x1: 12, y1: 20, x2: 12, y2: 22)                     // bottom
        addLine(ctx, x1: 2, y1: 12, x2: 4, y2: 12)                       // left
        addLine(ctx, x1: 20, y1: 12, x2: 22, y2: 12)                     // right
        addLine(ctx, x1: 4.93, y1: 4.93, x2: 6.34, y2: 6.34)            // top-left
        addLine(ctx, x1: 17.66, y1: 17.66, x2: 19.07, y2: 19.07)        // bottom-right
        addLine(ctx, x1: 6.34, y1: 17.66, x2: 4.93, y2: 19.07)          // bottom-left
        addLine(ctx, x1: 19.07, y1: 4.93, x2: 17.66, y2: 6.34)          // top-right
        ctx.strokePath()
    }

    /// Left-side + top + bottom rays only (volume mode)
    private static func drawLeftRays(_ ctx: CGContext) {
        addLine(ctx, x1: 12, y1: 2, x2: 12, y2: 4)                       // top
        addLine(ctx, x1: 12, y1: 20, x2: 12, y2: 22)                     // bottom
        addLine(ctx, x1: 2, y1: 12, x2: 4, y2: 12)                       // left
        addLine(ctx, x1: 4.93, y1: 4.93, x2: 6.34, y2: 6.34)            // top-left
        addLine(ctx, x1: 4.93, y1: 19.07, x2: 6.34, y2: 17.66)          // bottom-left
        ctx.strokePath()
    }

    /// Sound wave arcs on the right side (volume mode)
    private static func drawSoundArcs(_ ctx: CGContext) {
        // Inner arc: SVG path "M16 9a5 5 0 0 1 0 6"
        // Center (12,12), radius 5, from (16,9) to (16,15)
        let innerStart = atan2(CGFloat(-3), CGFloat(4))   // ~-0.6435 rad
        let innerEnd   = atan2(CGFloat(3), CGFloat(4))    // ~ 0.6435 rad
        ctx.addArc(center: pt(12, 12), radius: s(5),
                   startAngle: innerStart, endAngle: innerEnd, clockwise: false)
        ctx.strokePath()

        // Outer arc: SVG path "M19.36 5.64a9 9 0 0 1 0 12.73"
        // Center ~(13,12), radius 9, from (19.36,5.64) to (19.36,18.37)
        let outerStart = atan2(CGFloat(-6.36), CGFloat(6.36))  // ~-pi/4
        let outerEnd   = atan2(CGFloat(6.37), CGFloat(6.36))   // ~ pi/4
        ctx.addArc(center: pt(13, 12), radius: s(9),
                   startAngle: outerStart, endAngle: outerEnd, clockwise: false)
        ctx.strokePath()
    }

    /// Dot rays at the 8 positions (custom/dim mode) -- matches Lucide sun-dim
    private static func drawDotRays(_ ctx: CGContext) {
        let positions: [(CGFloat, CGFloat)] = [
            (12, 4), (20, 12), (12, 20), (4, 12),
            (17.66, 6.34), (17.66, 17.66), (6.34, 17.66), (6.34, 6.34)
        ]
        for (x, y) in positions {
            ctx.move(to: pt(x, y))
            ctx.addLine(to: CGPoint(x: s(x) + 0.01, y: s(y)))
        }
        ctx.strokePath()
    }

    // MARK: - Primitives

    private static func addLine(_ ctx: CGContext, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) {
        ctx.move(to: pt(x1, y1))
        ctx.addLine(to: pt(x2, y2))
    }
}
