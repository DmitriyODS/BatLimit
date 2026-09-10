#!/usr/bin/env swift
import AppKit

// Генератор иконки приложения: Resources/AppIcon.icns.
// Запуск: swift Tools/make-icon.swift

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/Resources"

func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    // Подложка: скруглённый квадрат в стиле macOS
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: rect.width * 0.2237,
                            yRadius: rect.width * 0.2237)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.42, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.44, blue: 0.28, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -90)

    // Батарея: корпус, носик и заполнение до «безопасного» уровня
    let bodyW = rect.width * 0.60
    let bodyH = bodyW * 0.52
    let body = NSRect(x: rect.midX - bodyW / 2 - rect.width * 0.02,
                      y: rect.midY - bodyH / 2,
                      width: bodyW, height: bodyH)
    let line = max(1, size * 0.028)
    NSColor.white.setStroke()
    let bodyPath = NSBezierPath(roundedRect: body,
                                xRadius: bodyH * 0.28, yRadius: bodyH * 0.28)
    bodyPath.lineWidth = line
    bodyPath.stroke()

    let nub = NSRect(x: body.maxX + line * 0.9, y: rect.midY - bodyH * 0.16,
                     width: bodyW * 0.07, height: bodyH * 0.32)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: nub, xRadius: nub.width * 0.4, yRadius: nub.width * 0.4).fill()

    let padding = line * 1.6
    let fillRect = NSRect(x: body.minX + padding, y: body.minY + padding,
                          width: (body.width - padding * 2) * 0.55,
                          height: body.height - padding * 2)
    NSBezierPath(roundedRect: fillRect,
                 xRadius: fillRect.height * 0.22,
                 yRadius: fillRect.height * 0.22).fill()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    icon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "BatLimit.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// Имена файлов задаёт iconutil: base@2x — это удвоенный размер в пикселях.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = png(icon(size: CGFloat(pixels)), pixels) else { continue }
        try data.write(to: URL(fileURLWithPath: iconset + "/" + name))
    }
}

try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset, "-o", outputDir + "/AppIcon.icns"]
try process.run()
process.waitUntilExit()
try? fm.removeItem(atPath: iconset)

if process.terminationStatus == 0 {
    print("AppIcon.icns создан в \(outputDir)")
} else {
    print("iconutil завершился с кодом \(process.terminationStatus)")
    exit(1)
}
