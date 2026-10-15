import AppKit

// Draws Folio's app icon at every size the Mac asks for into Folio/Assets.xcassets/AppIcon.appiconset.
//   swift Tools/make-icon.swift
let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Folio/Assets.xcassets/AppIcon.appiconset")

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = size / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)

    // The squircle of a macOS icon, inset as Apple's grid has it.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0x5B / 255, green: 0x63 / 255, blue: 0xD3 / 255, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0x7A / 255, green: 0x81 / 255, blue: 0xE6 / 255, alpha: 1),
               ending: NSColor(srgbRed: 0x4A / 255, green: 0x51 / 255, blue: 0xC2 / 255, alpha: 1))!.draw(in: shape, angle: -90)

    // A page with a folded corner and three lines of text.
    let page = NSRect(x: 322, y: 236, width: 380, height: 500)
    let fold: CGFloat = 108
    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: page.minX + 34, y: page.minY))
    paper.line(to: NSPoint(x: page.maxX - 34, y: page.minY))
    paper.curve(to: NSPoint(x: page.maxX, y: page.minY + 34), controlPoint1: NSPoint(x: page.maxX - 15, y: page.minY), controlPoint2: NSPoint(x: page.maxX, y: page.minY + 15))
    paper.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    paper.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    paper.line(to: NSPoint(x: page.minX + 34, y: page.maxY))
    paper.curve(to: NSPoint(x: page.minX, y: page.maxY - 34), controlPoint1: NSPoint(x: page.minX + 15, y: page.maxY), controlPoint2: NSPoint(x: page.minX, y: page.maxY - 15))
    paper.line(to: NSPoint(x: page.minX, y: page.minY + 34))
    paper.curve(to: NSPoint(x: page.minX + 34, y: page.minY), controlPoint1: NSPoint(x: page.minX, y: page.minY + 15), controlPoint2: NSPoint(x: page.minX + 15, y: page.minY))
    paper.close()
    NSGraphicsContext.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    paperShadow.shadowBlurRadius = 24
    paperShadow.shadowOffset = NSSize(width: 0, height: -10)
    paperShadow.set()
    NSColor.white.setFill()
    paper.fill()
    NSGraphicsContext.restoreGraphicsState()

    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 22))
    corner.curve(to: NSPoint(x: page.maxX - fold + 22, y: page.maxY - fold), controlPoint1: NSPoint(x: page.maxX - fold, y: page.maxY - fold + 8), controlPoint2: NSPoint(x: page.maxX - fold + 8, y: page.maxY - fold))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(srgbRed: 0xDD / 255, green: 0xDF / 255, blue: 0xF6 / 255, alpha: 1).setFill()
    corner.fill()

    let ink = NSColor(srgbRed: 0x5B / 255, green: 0x63 / 255, blue: 0xD3 / 255, alpha: 1)
    // A heading line and two lines of text, the heading bolder.
    for (index, width) in [CGFloat(210), 250, 170].enumerated() {
        let y = page.maxY - 190 - CGFloat(index) * 78
        let height: CGFloat = index == 0 ? 38 : 26
        let alpha: CGFloat = index == 0 ? 1 : 0.35
        ink.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 58, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(folder.path)")
