// Renders the ProcXRay app icon: a processor chip seen through an X-ray scan beam.
// Usage: swift tools/make-icon.swift <out-dir>   → writes AppIcon.icns (+ AppIcon-1024.png)
import AppKit
import CoreGraphics

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cyan: UInt32 = 0x5CF2FF
let S: CGFloat = 1024

/// Apple's macOS icon grid: 824×824 body centred on a 1024 canvas, ~185pt continuous-ish corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Chip geometry (centred).
let chip = CGRect(x: 512 - 190, y: 512 - 190, width: 380, height: 380)
let die = chip.insetBy(dx: 110, dy: 110)
let beamY: CGFloat = 560, beamH: CGFloat = 120

func drawChip(_ ctx: CGContext, color: CGColor, glow: CGFloat, lineScale: CGFloat = 1) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: glow, color: color)
    ctx.setStrokeColor(color)
    ctx.setFillColor(color)

    // Package outline
    ctx.setLineWidth(20 * lineScale)
    ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 46, cornerHeight: 46, transform: nil))
    ctx.strokePath()

    // Pins: 4 per side
    let pinLen: CGFloat = 62, pinW: CGFloat = 30
    for i in 0..<4 {
        let t = chip.minX + 70 + CGFloat(i) * ((chip.width - 140) / 3) - pinW / 2
        let u = chip.minY + 70 + CGFloat(i) * ((chip.height - 140) / 3) - pinW / 2
        for r in [
            CGRect(x: t, y: chip.maxY + 14, width: pinW, height: pinLen),          // top
            CGRect(x: t, y: chip.minY - 14 - pinLen, width: pinW, height: pinLen), // bottom
            CGRect(x: chip.minX - 14 - pinLen, y: u, width: pinLen, height: pinW), // left
            CGRect(x: chip.maxX + 14, y: u, width: pinLen, height: pinW),          // right
        ] {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 9, cornerHeight: 9, transform: nil))
        }
    }
    ctx.fillPath()

    // Die + traces (the "bones" the X-ray reveals)
    ctx.setLineWidth(14 * lineScale)
    ctx.addPath(CGPath(roundedRect: die, cornerWidth: 18, cornerHeight: 18, transform: nil))
    ctx.strokePath()
    ctx.setLineWidth(8 * lineScale)
    for (a, b) in [
        (CGPoint(x: die.minX, y: die.midY), CGPoint(x: chip.minX + 30, y: die.midY)),
        (CGPoint(x: die.maxX, y: die.midY), CGPoint(x: chip.maxX - 30, y: die.midY)),
        (CGPoint(x: die.midX, y: die.maxY), CGPoint(x: die.midX, y: chip.maxY - 30)),
        (CGPoint(x: die.midX, y: die.minY), CGPoint(x: die.midX, y: chip.minY + 30)),
    ] {
        ctx.move(to: a); ctx.addLine(to: b)
    }
    ctx.strokePath()
    // core dot
    let core = CGRect(x: die.midX - 26, y: die.midY - 26, width: 52, height: 52)
    ctx.fillEllipse(in: core)
    ctx.restoreGState()
}

func render() -> CGImage {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Drop shadow under the body
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
    ctx.addPath(bodyPath); ctx.setFillColor(rgb(0x0A1828)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()

    // Radiograph background: deep blue-black vertical gradient
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0x16304A), rgb(0x07111D)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])

    // Soft radial bloom behind the chip
    let bloom = CGGradient(colorsSpace: nil, colors: [rgb(cyan, 0.22), rgb(cyan, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: [])

    // Faint measurement grid
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.045)); ctx.setLineWidth(2)
    var g: CGFloat = body.minX + 41
    while g < body.maxX { ctx.move(to: CGPoint(x: g, y: body.minY)); ctx.addLine(to: CGPoint(x: g, y: body.maxY))
        ctx.move(to: CGPoint(x: body.minX, y: g)); ctx.addLine(to: CGPoint(x: body.maxX, y: g)); g += 82 }
    ctx.strokePath()

    // The chip, dim (unscanned)
    drawChip(ctx, color: rgb(cyan, 0.55), glow: 22)

    // Scan beam: soft band + bright core line
    let band = CGRect(x: body.minX, y: beamY - beamH / 2, width: body.width, height: beamH)
    let beam = CGGradient(colorsSpace: nil, colors: [rgb(cyan, 0), rgb(cyan, 0.30), rgb(cyan, 0)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(beam, start: CGPoint(x: 512, y: band.minY), end: CGPoint(x: 512, y: band.maxY), options: [])

    // Inside the beam the chip glows white-hot (the "x-ray" reveal)
    ctx.saveGState()
    ctx.clip(to: band.insetBy(dx: 0, dy: 14))
    drawChip(ctx, color: rgb(0xE8FDFF, 1), glow: 34, lineScale: 1.05)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18, color: rgb(cyan, 1))
    ctx.setFillColor(rgb(0xF2FEFF, 0.95))
    ctx.fill(CGRect(x: body.minX, y: beamY - 3, width: body.width, height: 6))
    ctx.restoreGState()

    // Top sheen
    let sheen = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.maxY - 260), options: [])
    ctx.restoreGState()

    // Hairline rim
    ctx.addPath(bodyPath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let master = render()
writePNG(master, size: 1024, to: outDir.appendingPathComponent("AppIcon-1024.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(master, size: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(master, size: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(outDir.path)/AppIcon.icns" : "iconutil failed")
