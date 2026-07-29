// Generate Resources/CyberView.icns — HUD corner brackets on a dark tile.
// Run: swift gen-icon.swift  (requires iconutil, ships with macOS)
import AppKit

let purple = NSColor(calibratedHue: 258.0 / 360.0, saturation: 0.85, brightness: 0.955, alpha: 1)
let green = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024.0

    // dark tile with a whisper of the purple tint
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSColor(srgbRed: 0.055, green: 0.045, blue: 0.11, alpha: 1).setFill()
    path.fill()
    purple.withAlphaComponent(0.30).setStroke()
    path.lineWidth = 8 * s
    path.stroke()

    // corner brackets
    let inset: CGFloat = 150 * s, arm: CGFloat = 175 * s, w: CGFloat = 30 * s
    let lft = tile.minX + inset, rgt = tile.maxX - inset
    let bot = tile.minY + inset, top = tile.maxY - inset
    purple.setFill()
    for (x, y, horiz) in [
        (lft, top, true), (lft, top, false),           // ┌
        (rgt - arm, top, true), (rgt, top, false),     // ┐
        (lft, bot, true), (lft, bot + arm - arm, false), // └ (v arm drawn upward below)
        (rgt - arm, bot, true), (rgt, bot, false),     // ┘
    ] {
        if horiz {
            NSRect(x: x, y: y - w / 2, width: arm, height: w).fill()
        } else {
            let y0 = (y == top) ? top - arm : bot
            NSRect(x: x - w / 2, y: y0, width: w, height: arm).fill()
        }
    }

    // mid-edge diamonds
    for c in [NSPoint(x: (lft + rgt) / 2, y: top), NSPoint(x: (lft + rgt) / 2, y: bot)] {
        let r: CGFloat = 26 * s
        let d = NSBezierPath()
        d.move(to: NSPoint(x: c.x, y: c.y + r))
        d.line(to: NSPoint(x: c.x + r, y: c.y))
        d.line(to: NSPoint(x: c.x, y: c.y - r))
        d.line(to: NSPoint(x: c.x - r, y: c.y))
        d.close()
        purple.withAlphaComponent(0.75).setFill()
        d.fill()
    }

    // green block cursor, bottom-left — the prompt lives here
    green.withAlphaComponent(0.92).setFill()
    NSRect(x: lft + 55 * s, y: bot + 55 * s, width: 62 * s, height: 96 * s).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "CyberView.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try! render(px: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(px: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try? FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", "CyberView.iconset", "-o", "Resources/CyberView.icns"]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Resources/CyberView.icns written" : "iconutil failed")
