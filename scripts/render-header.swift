// Renders the App Store product page header artwork.
// Usage: swift scripts/render-header.swift <output-dir>
import AppKit

let brand = NSColor(srgbRed: 0.0, green: 0.368, blue: 0.992, alpha: 1)
let deep = NSColor(srgbRed: 0.0, green: 0.16, blue: 0.55, alpha: 1)
let headline = "Your original FIT files. Shared directly."

func render(width: Int, height: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let w = CGFloat(width), h = CGFloat(height)
    let ctx = NSGraphicsContext.current!.cgContext

    // Background: brand blue fading to deep blue, with a soft glow behind the centre.
    NSGradient(starting: brand, ending: deep)!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: w / 2, y: h * 0.5), radius: 0,
              toCenter: NSPoint(x: w / 2, y: h * 0.5), radius: h * 0.75, options: [])

    // All content is scaled from the height and centred, so wide crops only lose background.
    let u = h / 1646
    let midY = h * 0.42
    // Centre the file-to-heart group; the ride trace fills the space to the left.
    let cx = w / 2 - 420 * u

    // Ride trace: elevation profile from the far left into the file.
    let fileW = 300 * u, fileH = 380 * u
    let fileRect = NSRect(x: cx - fileW / 2, y: midY - fileH / 2, width: fileW, height: fileH)
    let ride = NSBezierPath()
    var x: CGFloat = -40 * u
    let rideEnd = fileRect.minX - 40 * u
    ride.move(to: NSPoint(x: x, y: midY))
    while x < rideEnd {
        x = min(x + 12 * u, rideEnd)
        // Envelope fades the profile in from the left edge and flattens it into the file.
        let t = max(0, x) / rideEnd
        let env = sin(.pi * pow(t, 0.8))
        let y = midY + (sin(x / (170 * u)) * 90 * u + sin(x / (53 * u)) * 26 * u) * env
        ride.line(to: NSPoint(x: x, y: y))
    }
    ride.lineWidth = 22 * u
    ride.lineCapStyle = .round
    ride.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.9).setStroke()
    ride.stroke()

    // Arc bridging the gap from the file to health, echoing the app icon.
    let heartC = NSPoint(x: cx + 820 * u, y: midY)
    let bridge = NSBezierPath()
    bridge.move(to: NSPoint(x: fileRect.maxX + 40 * u, y: midY))
    bridge.curve(to: NSPoint(x: heartC.x - 190 * u, y: midY),
                 controlPoint1: NSPoint(x: fileRect.maxX + 160 * u, y: midY + 230 * u),
                 controlPoint2: NSPoint(x: heartC.x - 310 * u, y: midY + 230 * u))
    bridge.lineWidth = 22 * u
    bridge.lineCapStyle = .round
    bridge.setLineDash([2 * u, 48 * u], count: 2, phase: 0)
    NSColor.white.setStroke()
    bridge.stroke()

    // File card with folded corner and ".FIT" label.
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * u), blur: 60 * u,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    let fold = 80 * u
    let file = NSBezierPath()
    file.move(to: NSPoint(x: fileRect.minX, y: fileRect.minY))
    file.line(to: NSPoint(x: fileRect.maxX, y: fileRect.minY))
    file.line(to: NSPoint(x: fileRect.maxX, y: fileRect.maxY - fold))
    file.line(to: NSPoint(x: fileRect.maxX - fold, y: fileRect.maxY))
    file.line(to: NSPoint(x: fileRect.minX, y: fileRect.maxY))
    file.close()
    NSColor.white.setFill()
    file.fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: fileRect.maxX - fold, y: fileRect.maxY))
    corner.line(to: NSPoint(x: fileRect.maxX - fold, y: fileRect.maxY - fold))
    corner.line(to: NSPoint(x: fileRect.maxX, y: fileRect.maxY - fold))
    corner.close()
    NSColor(srgbRed: 0.78, green: 0.85, blue: 1, alpha: 1).setFill()
    corner.fill()
    let label = NSAttributedString(string: ".FIT", attributes: [
        .font: NSFont.systemFont(ofSize: 96 * u, weight: .heavy),
        .foregroundColor: brand,
    ])
    let ls = label.size()
    label.draw(at: NSPoint(x: fileRect.midX - ls.width / 2, y: fileRect.minY + 70 * u))
    for i in 0..<2 {
        let bar = NSBezierPath(roundedRect: NSRect(x: fileRect.minX + 60 * u, y: fileRect.maxY - 150 * u - CGFloat(i) * 56 * u,
                                                   width: (i == 0 ? 130 : 180) * u, height: 22 * u),
                               xRadius: 11 * u, yRadius: 11 * u)
        brand.withAlphaComponent(0.25).setFill()
        bar.fill()
    }

    // Health destination: heart in a white disc.
    ctx.setShadow(offset: CGSize(width: 0, height: -24 * u), blur: 60 * u,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    let r = 170 * u
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: heartC.x - r, y: heartC.y - r, width: 2 * r, height: 2 * r)).fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    let cfg = NSImage.SymbolConfiguration(pointSize: 170 * u, weight: .bold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.22, blue: 0.36, alpha: 1)]))
    if let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let s = heart.size
        heart.draw(in: NSRect(x: heartC.x - s.width / 2, y: heartC.y - s.height / 2 - 6 * u, width: s.width, height: s.height))
    }

    // Headline above the motif.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let title = NSAttributedString(string: headline, attributes: [
        .font: NSFont.systemFont(ofSize: 112 * u, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: para,
        .kern: -1.5 * u,
    ])
    let ts = title.size()
    title.draw(at: NSPoint(x: w / 2 - ts.width / 2, y: midY + 400 * u))

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
render(width: 5244, height: 2950, to: out.appendingPathComponent("header-5244x2950.png"))
render(width: 3840, height: 1646, to: out.appendingPathComponent("header-3840x1646.png"))
