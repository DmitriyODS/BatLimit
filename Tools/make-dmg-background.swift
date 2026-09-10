#!/usr/bin/env swift
import AppKit

// Генератор фона для окна DMG.
// Запуск: swift Tools/make-dmg-background.swift build/dmg-background.png
//
// Размер строго 660×440 пикселей: Finder рисует фон попиксельно, без учёта
// масштаба, поэтому картинка «в два раза больше для Retina» просто растянет
// окно вдвое. Позиции значков в build.sh привязаны к этой же сетке.

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/build/dmg-background.png"

let W: CGFloat = 660
let H: CGFloat = 440

// Координаты значков в системе Finder (начало отсчёта — верхний левый угол).
// Здесь переводим в систему AppKit (начало — нижний левый).
func appKitY(_ finderY: CGFloat) -> CGFloat { H - finderY }
let appSlot   = NSPoint(x: 170, y: appKitY(170))
let dropSlot  = NSPoint(x: 490, y: appKitY(170))
let setupSlot = NSPoint(x: 170, y: appKitY(335))

let ink       = NSColor(calibratedWhite: 0.13, alpha: 1)
let inkSoft   = NSColor(calibratedWhite: 0.42, alpha: 1)
let accent    = NSColor(calibratedRed: 0.13, green: 0.58, blue: 0.35, alpha: 1)

func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight,
          color: NSColor, centered: Bool = false, maxWidth: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = centered ? .center : .left
    style.lineSpacing = 3
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let string = NSAttributedString(string: text, attributes: attrs)
    if maxWidth > 0 {
        let box = NSRect(x: point.x, y: point.y - 200, width: maxWidth, height: 200)
        // Рисуем в прямоугольник высотой с запасом и «подвешиваем» за верх.
        let needed = string.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        string.draw(with: NSRect(x: box.minX, y: point.y - needed.height,
                                 width: maxWidth, height: needed.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
    } else if centered {
        let size = string.size()
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y))
    } else {
        string.draw(at: point)
    }
}

// Растр задаём явно, а не через `NSImage.lockFocus()`: тот рисует в масштабе
// текущего экрана, и на Retina получилось бы 1320×880 — Finder растянул бы
// окно вдвое, потому что считает фон попиксельно.
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: Int(W), pixelsHigh: Int(H),
                                    bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write("не удалось создать растр\n".data(using: .utf8)!)
    exit(1)
}
bitmap.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

// Фон: очень мягкий вертикальный градиент, чтобы значки не «висели в пустоте».
NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.99, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.90, green: 0.94, blue: 0.91, alpha: 1),
])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// Заголовок
draw("BatLimit", at: NSPoint(x: W / 2, y: H - 62), size: 30, weight: .semibold,
     color: ink, centered: true)
draw("ограничитель зарядки батареи", at: NSPoint(x: W / 2, y: H - 88),
     size: 13, weight: .regular, color: inkSoft, centered: true)

// Стрелка от значка программы к «Программам». Кончики стрелки не доводим до
// значков вплотную: между ними ещё подпись, которую рисует сам Finder.
let arrowY = appSlot.y
let from = appSlot.x + 78
let to = dropSlot.x - 78
accent.withAlphaComponent(0.55).setStroke()
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: from, y: arrowY))
shaft.line(to: NSPoint(x: to - 14, y: arrowY))
shaft.lineWidth = 3
shaft.lineCapStyle = .round
shaft.setLineDash([1, 9], count: 2, phase: 0)
shaft.stroke()

accent.withAlphaComponent(0.75).setFill()
let head = NSBezierPath()
head.move(to: NSPoint(x: to, y: arrowY))
head.line(to: NSPoint(x: to - 16, y: arrowY + 9))
head.line(to: NSPoint(x: to - 16, y: arrowY - 9))
head.close()
head.fill()

draw("перетащи", at: NSPoint(x: (from + to) / 2, y: arrowY + 16),
     size: 12, weight: .medium, color: accent, centered: true)

// Разделитель между «перетащить» и «запустить скрипт»
NSColor(calibratedWhite: 0.55, alpha: 0.22).setFill()
NSRect(x: 60, y: 196, width: W - 120, height: 1).fill()

// Подсказка про установщик — справа от его значка.
let hintX = setupSlot.x + 90
draw("Проще — через установщик", at: NSPoint(x: hintX, y: 148),
     size: 14, weight: .semibold, color: ink)
draw("Нажми на него правой кнопкой → «Открыть».\n"
     + "Он проверит, подходит ли этот Mac, снимет карантин\n"
     + "Gatekeeper и запустит программу.",
     at: NSPoint(x: hintX, y: 140), size: 12, weight: .regular,
     color: inkSoft, maxWidth: W - hintX - 40)

// Сноска: почему вообще нужны эти пляски.
draw("Сборка не подписана Developer ID — поэтому macOS и требует подтверждения.",
     at: NSPoint(x: W / 2, y: 22), size: 11, weight: .regular,
     color: NSColor(calibratedWhite: 0.55, alpha: 1), centered: true)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("не удалось отрисовать фон\n".data(using: .utf8)!)
    exit(1)
}

let url = URL(fileURLWithPath: output)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
do {
    try png.write(to: url)
    print("Фон DMG: \(url.path) (\(Int(W))×\(Int(H)))")
} catch {
    FileHandle.standardError.write("не удалось записать \(output): \(error)\n".data(using: .utf8)!)
    exit(1)
}
