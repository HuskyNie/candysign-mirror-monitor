import AppKit

enum Artwork {
    static func status(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 16, height: 14), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.4
            outline.stroke()
            if connected {
                NSColor.black.setFill()
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 11, y: 14))
                for point in [NSPoint(x: 6.5, y: 8), NSPoint(x: 9.5, y: 8), NSPoint(x: 9, y: 4), NSPoint(x: 13.5, y: 10), NSPoint(x: 10.5, y: 10)] {
                    bolt.line(to: point)
                }
                bolt.close()
                bolt.fill()
            } else {
                // Erase beneath the slash to keep the disconnected silhouette clear.
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2, y: 17))
                slash.line(to: NSPoint(x: 18, y: 1))
                slash.lineCapStyle = .round
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .clear
                slash.lineWidth = 4
                slash.stroke()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.setStroke()
                slash.lineWidth = 1.5
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = connected ? "小电拼已连接" : "小电拼未连接"
        return image
    }

    // Vector artwork shared by the reproducible app-icon generator.
    static func drawAppIcon() {
        let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.25, alpha: 1),
                   ending: NSColor(calibratedRed: 0.025, green: 0.065, blue: 0.10, alpha: 1))!.draw(in: background, angle: -55)

        let body = NSBezierPath(roundedRect: NSRect(x: 224, y: 186, width: 576, height: 652), xRadius: 110, yRadius: 110)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -22)
        shadow.set()
        NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.93, alpha: 1).setFill()
        body.fill()
        NSGraphicsContext.restoreGraphicsState()

        let screen = NSBezierPath(roundedRect: NSRect(x: 278, y: 368, width: 468, height: 408), xRadius: 65, yRadius: 65)
        NSColor(calibratedRed: 0.055, green: 0.13, blue: 0.16, alpha: 1).setFill()
        screen.fill()
        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: 548, y: 723))
        for point in [NSPoint(x: 405, y: 547), NSPoint(x: 503, y: 547), NSPoint(x: 478, y: 429), NSPoint(x: 623, y: 613), NSPoint(x: 524, y: 613)] {
            bolt.line(to: point)
        }
        bolt.close()
        NSColor(calibratedRed: 0.33, green: 0.93, blue: 0.74, alpha: 1).setFill()
        bolt.fill()

        // Five output indicators echo the device's 4C1A layout.
        for index in 0..<5 {
            let port = NSBezierPath(roundedRect: NSRect(x: 300 + index * 88, y: 267, width: 72, height: 32), xRadius: index == 4 ? 4 : 16, yRadius: index == 4 ? 4 : 16)
            NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.27, alpha: 1).setFill()
            port.fill()
        }
    }
}
