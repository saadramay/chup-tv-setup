import AppKit

/// Renders Chup Setup's icon at every size macOS asks for, then build.sh runs iconutil over
/// the result. Kept in the repo so the icon can be changed without a design tool.
@main
struct IconGen {
    static let sizes: [Int: [String]] = [
        16:    ["icon_16x16.png"],
        32:    ["icon_16x16@2x.png", "icon_32x32.png"],
        64:    ["icon_32x32@2x.png"],
        128:   ["icon_128x128.png"],
        256:   ["icon_128x128@2x.png", "icon_256x256.png"],
        512:   ["icon_256x256@2x.png", "icon_512x512.png"],
        1024:  ["icon_512x512@2x.png"],
    ]

    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
        let fm = FileManager.default
        try? fm.removeItem(atPath: outDir)
        try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for (px, names) in sizes {
            guard let rep = render(px), let png = rep.representation(using: .png, properties: [:])
            else { continue }
            for name in names {
                let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
                try! png.write(to: url)
            }
        }
        print("wrote \(outDir)")
    }

    static func render(_ pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        drawIcon(size: CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func drawIcon(size s: CGFloat) {
        // Plate. AppKit draws from the bottom-left, so y grows upward.
        let plate = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.03, dy: s * 0.03)
        let bg = NSBezierPath(roundedRect: plate, xRadius: s * 0.215, yRadius: s * 0.215)
        NSGradient(colors: [
            NSColor(red: 0.11, green: 0.22, blue: 0.40, alpha: 1),
            NSColor(red: 0.03, green: 0.07, blue: 0.15, alpha: 1),
        ])!.draw(in: bg, angle: -90)

        let chalk = NSColor(white: 0.96, alpha: 1)

        // Screen
        let tv = NSBezierPath(
            roundedRect: NSRect(x: s * 0.19, y: s * 0.36, width: s * 0.62, height: s * 0.42),
            xRadius: s * 0.05, yRadius: s * 0.05)
        chalk.setStroke()
        tv.lineWidth = s * 0.05
        tv.stroke()

        // Stand
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: s * 0.43, y: s * 0.36))
        stand.line(to: NSPoint(x: s * 0.43, y: s * 0.30))
        stand.line(to: NSPoint(x: s * 0.57, y: s * 0.30))
        stand.line(to: NSPoint(x: s * 0.57, y: s * 0.36))
        stand.lineWidth = s * 0.045
        stand.lineCapStyle = .round
        stand.lineJoinStyle = .round
        chalk.setStroke()
        stand.stroke()

        // Tick, sitting over the screen
        let check = NSBezierPath()
        check.move(to: NSPoint(x: s * 0.34, y: s * 0.555))
        check.line(to: NSPoint(x: s * 0.455, y: s * 0.445))
        check.line(to: NSPoint(x: s * 0.675, y: s * 0.665))
        check.lineWidth = s * 0.06
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        NSColor(calibratedRed: 0.32, green: 0.86, blue: 0.47, alpha: 1).setStroke()
        check.stroke()
    }
}
