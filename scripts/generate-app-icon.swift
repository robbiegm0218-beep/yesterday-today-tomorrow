import AppKit
import Foundation

// Package the generated illustration into native macOS sizes; no redraw of artwork.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let artwork = NSImage(contentsOfFile: CommandLine.arguments[3])!
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let rect = NSRect(x: 88, y: 88, width: 848, height: 848)
    NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190).addClip()
    artwork.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// Encode the standard PNG-backed ICNS chunks directly. This avoids relying on
// iconutil's image-service availability during a local sandboxed build.
if CommandLine.arguments.count > 2 {
    func bigEndian(_ value: Int) -> Data {
        var bytes = UInt32(value).bigEndian
        return withUnsafeBytes(of: &bytes) { Data($0) }
    }
    var chunks = Data()
    for (kind, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
        let png = try render(size)
        chunks.append(Data(kind.utf8)); chunks.append(bigEndian(png.count + 8)); chunks.append(png)
    }
    var icon = Data("icns".utf8); icon.append(bigEndian(chunks.count + 8)); icon.append(chunks)
    try icon.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
}
