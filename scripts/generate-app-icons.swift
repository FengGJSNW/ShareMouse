// Rebuild platform containers from the checked-in imagegen masters. Run from the repo root.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("resources/app-icon")
let temporary = root.appendingPathComponent("artifacts/app-icon-export")
let iconset = temporary.appendingPathComponent("ShareMouse.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func source(_ name: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(assets.appendingPathComponent(name) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
// Normalize the visible artwork, rather than scaling the transparent source canvas.
func artworkBounds(_ image: CGImage) -> CGRect {
    let width = image.width, height = image.height
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var left = width, top = height, right = 0, bottom = 0
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 128 {
            left = min(left, x); top = min(top, y)
            right = max(right, x + 1); bottom = max(bottom, y + 1)
        }
    }
    precondition(right > left && bottom > top, "The icon master is empty")
    return CGRect(x: left, y: top, width: right - left, height: bottom - top)
}
func png(_ image: CGImage, _ size: Int, artworkFraction: CGFloat? = nil) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    if let fraction = artworkFraction {
        let bounds = artworkBounds(image)
        // Two source pixels retain antialiasing around the measured opaque silhouette.
        let crop = bounds.insetBy(dx: -2, dy: -2).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let artwork = image.cropping(to: crop)!
        let scale = CGFloat(size) * fraction / max(bounds.width, bounds.height)
        let width = CGFloat(artwork.width) * scale, height = CGFloat(artwork.height) * scale
        ctx.draw(artwork, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2,
                                    width: width, height: height))
    } else {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest))
    return data as Data
}
let mac = source("macos-master.png")
for size in [16, 32, 128, 256, 512] {
    try png(mac, size, artworkFraction: 0.88).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(mac, size * 2, artworkFraction: 0.88).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("ShareMouse.icns").path]
try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
let win = source("windows-master.png")
let sizes = [16, 20, 24, 28, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 128, 256]
let frames = sizes.map { png(win, $0, artworkFraction: 0.96) }
var ico = Data()
func u16(_ n: Int) { var v = UInt16(n).littleEndian; withUnsafeBytes(of: &v) { ico.append(contentsOf: $0) } }
func u32(_ n: Int) { var v = UInt32(n).littleEndian; withUnsafeBytes(of: &v) { ico.append(contentsOf: $0) } }
u16(0); u16(1); u16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, frame) in zip(sizes, frames) {
    ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0])
    u16(1); u16(32); u32(frame.count); u32(offset); offset += frame.count
}
frames.forEach { ico.append($0) }
try ico.write(to: assets.appendingPathComponent("ShareMouse.ico"))
// A deliberately simplified vector companion for the 18 pt macOS menu bar.
let ctx = CGContext(data: nil, width: 36, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: 36); ctx.scaleBy(x: 1.125, y: -1.125)
ctx.setStrokeColor(NSColor.black.cgColor); ctx.setFillColor(NSColor.black.cgColor)
ctx.setLineWidth(2.4); ctx.setLineJoin(.round); ctx.setLineCap(.round)
// Open boundary plus a single up-right pointer, matching the second design.
ctx.setLineWidth(3.2)
ctx.move(to: CGPoint(x: 10, y: 13))
ctx.addLine(to: CGPoint(x: 10, y: 8))
ctx.addQuadCurve(to: CGPoint(x: 14, y: 4), control: CGPoint(x: 10, y: 4))
ctx.addLine(to: CGPoint(x: 25, y: 4))
ctx.addQuadCurve(to: CGPoint(x: 29, y: 8), control: CGPoint(x: 29, y: 4))
ctx.addLine(to: CGPoint(x: 29, y: 22))
ctx.addQuadCurve(to: CGPoint(x: 25, y: 26), control: CGPoint(x: 29, y: 26))
ctx.addLine(to: CGPoint(x: 21, y: 26)); ctx.strokePath()
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 22, y: 12))
for point in [CGPoint(x:17,y:29),CGPoint(x:13,y:24),CGPoint(x:7,y:30),CGPoint(x:3,y:26),CGPoint(x:9,y:20),CGPoint(x:4,y:17)] { arrow.addLine(to: point) }
arrow.closeSubpath()
ctx.setBlendMode(.clear);ctx.setLineWidth(2.5);ctx.addPath(arrow);ctx.drawPath(using:.fillStroke)
ctx.setBlendMode(.normal);ctx.addPath(arrow);ctx.fillPath()
try png(ctx.makeImage()!, 36).write(to: assets.appendingPathComponent("MenuBarTemplate.png"))
print("Exported ICNS 16–1024 px, ICO sixteen sizes 16–256 px, and monochrome menu template.")
