import AppKit

/// The menu bar glyph: the app icon's sun setting behind two waves, drawn as a template image
/// (macOS tints it for light, dark and highlighted menu bars).
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            func wave(y: CGFloat) -> NSBezierPath {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                var x: CGFloat = 1
                path.move(to: NSPoint(x: x, y: y))
                while x < 17 {
                    x += 0.5
                    path.line(to: NSPoint(x: x, y: y + 1.2 * sin((x - 1) / 16 * 2 * .pi)))
                }
                return path
            }
            let horizon = wave(y: 7.5)

            // Sun, then cut away everything at and below the horizon, leaving a thin gap above the wave.
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4.2, y: 7.4, width: 9.6, height: 9.6)).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            let below = horizon.copy() as! NSBezierPath
            below.line(to: NSPoint(x: 17, y: -1))
            below.line(to: NSPoint(x: 1, y: -1))
            below.close()
            below.fill()
            horizon.lineWidth = 3.6
            horizon.stroke()

            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            horizon.lineWidth = 1.7
            horizon.stroke()
            let lower = wave(y: 3.6)
            lower.lineWidth = 1.7
            lower.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Tide"
        return image
    }
}
