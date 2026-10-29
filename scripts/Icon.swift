import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.91, green: 0.96, blue: 0.93, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 218, yRadius: 218).fill()
        NSColor(calibratedRed: 0.13, green: 0.46, blue: 0.43, alpha: 0.25).setStroke()
        let outer = NSBezierPath(ovalIn: NSRect(x: 205, y: 177, width: 614, height: 162)); outer.lineWidth = 17; outer.stroke()
        let inner = NSBezierPath(ovalIn: NSRect(x: 307, y: 211, width: 410, height: 95)); inner.lineWidth = 12; inner.stroke()
        let drop = NSBezierPath()
        drop.move(to: NSPoint(x: 512, y: 830))
        drop.curve(to: NSPoint(x: 303, y: 444), controlPoint1: NSPoint(x: 481, y: 755), controlPoint2: NSPoint(x: 303, y: 578))
        drop.curve(to: NSPoint(x: 721, y: 444), controlPoint1: NSPoint(x: 303, y: 173), controlPoint2: NSPoint(x: 721, y: 173))
        drop.curve(to: NSPoint(x: 512, y: 830), controlPoint1: NSPoint(x: 721, y: 578), controlPoint2: NSPoint(x: 543, y: 755))
        drop.close()
        NSColor(calibratedRed: 0.13, green: 0.46, blue: 0.43, alpha: 1).setFill(); drop.fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

// Modern ICNS resources contain PNG representations. Package the generated
// bytes directly so building does not depend on iconutil's helper processes.
func bigEndianLength(_ length: Int) -> Data {
    var length = UInt32(length).bigEndian
    return withUnsafeBytes(of: &length) { Data($0) }
}
var resources = Data()
for (type, filename) in [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
                         ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"),
                         ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png")] {
    let png = try Data(contentsOf: directory.appendingPathComponent(filename))
    resources.append(Data(type.utf8)); resources.append(bigEndianLength(png.count + 8)); resources.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndianLength(resources.count + 8)); icon.append(resources)
try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
