// Generates AppIcon.icns: a lightning bolt on a rounded-rect gradient.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetPath = "\(outputDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func drawIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.29, green: 0.33, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.62, green: 0.26, blue: 0.93, alpha: 1)
    )
    gradient?.draw(in: path, angle: -60)

    // Lightning bolt built from a polygon, scaled to the canvas.
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [
        (0.56, 0.88), (0.30, 0.50), (0.46, 0.50),
        (0.42, 0.14), (0.70, 0.54), (0.53, 0.54),
    ]
    bolt.move(to: NSPoint(x: points[0].0 * s, y: points[0].1 * s))
    for p in points.dropFirst() {
        bolt.line(to: NSPoint(x: p.0 * s, y: p.1 * s))
    }
    bolt.close()
    NSColor.white.setFill()
    bolt.fill()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String, pixels: Int) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

for size in [16, 32, 128, 256, 512] {
    savePNG(drawIcon(size: size), to: "\(iconsetPath)/icon_\(size)x\(size).png", pixels: size)
    savePNG(drawIcon(size: size * 2), to: "\(iconsetPath)/icon_\(size)x\(size)@2x.png", pixels: size * 2)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetPath, "-o", "\(outputDir)/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconsetPath)
print("Wrote \(outputDir)/AppIcon.icns")
