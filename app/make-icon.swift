import AppKit

/// Renders Chup Setup's icon at every size macOS asks for, then build.sh runs iconutil over
/// the result. The artwork is the real chup! brand mark and wordmark, read from
/// logo/chup-wordmark.svg, so there is no design tool in the loop and no redrawn lookalike.
///
/// At icon sizes the wordmark is a smudge: below 41px only the mark is drawn, which is what
/// the Dock and Finder actually show.
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

    /// Brand green from the book, dark end of the plate's gradient to darker end.
    static let plateTop = NSColor(red: 0.106, green: 0.478, blue: 0.271, alpha: 1)
    static let plateBottom = NSColor(red: 0.039, green: 0.227, blue: 0.125, alpha: 1)
    /// The wordmark is the reverse of the green-on-white lockup, so it is drawn in white.
    static let ink = NSColor(white: 0.98, alpha: 1)

    /// Below this the wordmark is unreadable and only the mark earns its pixels.
    static let markOnlyBelow: CGFloat = 41

    static func main() {
        let args = CommandLine.arguments
        let outDir = args.count > 1 ? args[1] : "AppIcon.iconset"
        let svgPath = args.count > 2 ? args[2] : "logo/chup-wordmark.svg"
        let artwork = Artwork(svgPath)

        let fm = FileManager.default
        try? fm.removeItem(atPath: outDir)
        try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for (px, names) in sizes {
            guard let rep = render(px, artwork: artwork),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            for name in names {
                let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
                try! png.write(to: url)
            }
        }
        print("wrote \(outDir) from \(svgPath)")
    }

    static func render(_ pixels: Int, artwork: Artwork) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        drawIcon(size: CGFloat(pixels), artwork: artwork)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func drawIcon(size s: CGFloat, artwork: Artwork) {
        // Plate. AppKit draws from the bottom-left, so y grows upward.
        let plate = NSRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.03, dy: s * 0.03)
        let bg = NSBezierPath(roundedRect: plate, xRadius: s * 0.215, yRadius: s * 0.215)
        NSGradient(colors: [plateTop, plateBottom])!.draw(in: bg, angle: -90)

        // Whichever artwork this size can actually carry. A mark that is optically centred
        // sits slightly low, so the box is nudged up.
        let markOnly = s < markOnlyBelow
        let art = markOnly ? artwork.mark : artwork.wordmark
        let width = markOnly ? s * 0.52 : s * 0.78
        let height = width * aspect(of: art)
        let box = NSRect(x: (s - width) / 2, y: (s - height) / 2 + s * 0.015,
                         width: width, height: height)
        ink.setFill()
        fitted(art, to: box).fill()
    }

    static func aspect(of path: NSBezierPath) -> CGFloat {
        let b = path.controlPointBounds
        return b.width > 0 ? b.height / b.width : 1
    }

    /// The path transformed so its own bounds land on `rect`, with SVG's y-down flipped to
    /// AppKit's y-up.
    static func fitted(_ path: NSBezierPath, to rect: NSRect) -> NSBezierPath {
        let copy = path.copy() as! NSBezierPath
        let b = copy.controlPointBounds
        guard b.width > 0, b.height > 0 else { return copy }
        let scale = min(rect.width / b.width, rect.height / b.height)
        let tx = rect.midX - b.midX * scale
        let ty = rect.midY + b.midY * scale
        let transform = AffineTransform(m11: scale, m12: 0, m21: 0, m22: -scale, tX: tx, tY: ty)
        copy.transform(using: transform)
        return copy
    }
}

/// The two <path> elements of the brand SVG: the mark on its own, and the wordmark.
struct Artwork {
    let mark: NSBezierPath
    let wordmark: NSBezierPath

    /// Reads the SVG. With nothing readable in it, both pieces are empty paths and the icon
    /// comes out as a bare plate rather than the build failing.
    init(_ svgPath: String) {
        var found: [String: NSBezierPath] = [:]
        if let svg = try? String(contentsOfFile: svgPath, encoding: .utf8) {
            for (id, d) in IconGen.pathAttributes(in: svg) {
                found[id] = IconGen.bezier(from: d)
            }
        }
        mark = found["mark"] ?? NSBezierPath()
        wordmark = found["wordmark"] ?? (found["mark"] ?? NSBezierPath())
    }
}

extension IconGen {
    /// Every <path>'s id and d, in document order. ids are how the mark and the wordmark are
    /// told apart; a path without one is filed under its position.
    static func pathAttributes(in svg: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let text = svg as NSString
        let full = NSRange(location: 0, length: text.length)
        guard let re = try? NSRegularExpression(pattern: "<path\\b[^>]*>") else { return out }
        for match in re.matches(in: svg, range: full) {
            let tag = text.substring(with: match.range)
            guard let d = attribute("d", in: tag) else { continue }
            out.append((attribute("id", in: tag) ?? "\(out.count)", d))
        }
        return out
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        // \bd= so the d in id="mark" is not mistaken for the path data attribute.
        guard let re = try? NSRegularExpression(pattern: "\\b\(name)=\"([^\"]*)\""),
              let match = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              match.numberOfRanges > 1
        else { return nil }
        return (tag as NSString).substring(with: match.range(at: 1))
    }

    /// SVG path data to an NSBezierPath. Handles M L C Z, absolute and relative, plus H and V
    /// -- the brand mark needs only the first four, and the rest cost nothing to carry.
    static func bezier(from d: String) -> NSBezierPath {
        let path = NSBezierPath()
        var tokens = tokens(in: d)
        var current = NSPoint.zero
        var start = NSPoint.zero
        var command = ""

        func num() -> CGFloat {
            guard !tokens.isEmpty else { return 0 }
            return CGFloat(Double(tokens.removeFirst()) ?? 0)
        }
        func point(relative: Bool) -> NSPoint {
            let x = num(), y = num()
            return relative ? NSPoint(x: current.x + x, y: current.y + y) : NSPoint(x: x, y: y)
        }

        while !tokens.isEmpty {
            let next = tokens.removeFirst()
            if let first = next.first, letters.contains(first) {
                command = next
            } else if command.isEmpty {
                continue
            } else {
                // A number with no letter in front repeats the previous command, and an extra
                // coordinate pair after a moveto is an implicit lineto.
                if command == "M" { command = "L" }
                if command == "m" { command = "l" }
                tokens.insert(next, at: 0)
            }

            let upper = command.uppercased()
            let relative = command != upper
            switch upper {
            case "M":
                let p = point(relative: relative)
                path.move(to: p)
                current = p; start = p
            case "L":
                let p = point(relative: relative)
                path.line(to: p)
                current = p
            case "H":
                let x = num()
                let p = NSPoint(x: relative ? current.x + x : x, y: current.y)
                path.line(to: p); current = p
            case "V":
                let y = num()
                let p = NSPoint(x: current.x, y: relative ? current.y + y : y)
                path.line(to: p); current = p
            case "C":
                let c1 = point(relative: relative)
                let c2 = point(relative: relative)
                let p = point(relative: relative)
                path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
                current = p
            case "Z":
                path.close()
                current = start
            default:
                // An unsupported command: drop the numbers that belong to it, or the loop
                // would keep meeting the same number forever.
                while let head = tokens.first, head.first.map({ !letters.contains($0) }) ?? false {
                    _ = tokens.removeFirst()
                }
            }
        }
        return path
    }

    static let letters: Set<Character> = Set("MmLlHhVvCcSsQqTtAaZz")

    /// Path data into commands and numbers, keeping each minus sign with its own number.
    static func tokens(in d: String) -> [String] {
        var out: [String] = []
        var number = ""
        func flush() {
            if !number.isEmpty { out.append(number); number = "" }
        }
        for ch in d {
            if ch.isNumber || ch == "." || ch == "e" || ch == "E" {
                number.append(ch)
            } else if ch == "-" || ch == "+" {
                // A sign starts a new number, unless it is the exponent's sign.
                if number.isEmpty || (number.last != "e" && number.last != "E") { flush() }
                number.append(ch)
            } else if letters.contains(ch) {
                flush()
                out.append(String(ch))
            } else {
                flush()             // commas and whitespace separate numbers
            }
        }
        flush()
        return out
    }
}
