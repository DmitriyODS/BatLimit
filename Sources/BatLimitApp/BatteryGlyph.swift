import AppKit

// Значок батареи для строки меню. Рисуем сами, а не берём готовый символ
// `battery.*percent`: у системного набора уровень задан ступенями по 25 %,
// а нам нужен настоящий заряд и метка состояния BatLimit внутри корпуса.

enum BatteryGlyph {

    /// Что BatLimit делает с зарядкой — метка внутри корпуса.
    enum Badge {
        case none
        case hold       // зарядка удержана нами
        case charging   // идёт зарядка
        case settling   // команда отправлена, контроллер ещё не применил
        case plugged    // от сети, но не заряжается и не удерживается
        case warning    // служба не отвечает

        var symbolName: String? {
            switch self {
            case .none:     return nil
            case .hold:     return "pause.fill"
            case .charging: return "bolt.fill"
            case .settling: return "hourglass"
            case .plugged:  return "powerplug.fill"
            case .warning:  return "exclamationmark"
            }
        }
    }

    // Размеры подобраны под системный индикатор батареи: рядом с ним наш
    // значок не должен выглядеть ни крупнее, ни мельче.
    private static let size = NSSize(width: 26, height: 14)
    private static let body = NSRect(x: 0.5, y: 1.25, width: 22, height: 11.5)
    private static let bodyRadius: CGFloat = 3.4
    private static let outlineAlpha: CGFloat = 0.45
    /// Отступ заливки от внутреннего края корпуса.
    private static let fillInset: CGFloat = 2

    static func image(percentage: Int, badge: Badge) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            drawOutline()
            let fill = drawFill(percentage: percentage)
            if let name = badge.symbolName { drawBadge(name, fillMaxX: fill) }
            return true
        }
        // Шаблон: цвет значка подбирает строка меню — и в светлой теме,
        // и в тёмной, и под выделением открытого меню.
        image.isTemplate = true
        return image
    }

    /// Корпус и «рожок» — приглушённые, как у системного значка: рамка не
    /// должна спорить с заливкой, по которой и читается заряд.
    private static func drawOutline() {
        NSColor.black.withAlphaComponent(outlineAlpha).setStroke()
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: bodyRadius - 0.5, yRadius: bodyRadius - 0.5)
        outline.lineWidth = 1
        outline.stroke()

        NSColor.black.withAlphaComponent(outlineAlpha).setFill()
        let nub = NSBezierPath()
        let x = body.maxX + 0.7
        nub.move(to: NSPoint(x: x, y: size.height / 2 - 2.1))
        nub.curve(to: NSPoint(x: x, y: size.height / 2 + 2.1),
                  controlPoint1: NSPoint(x: x + 2.6, y: size.height / 2 - 1.6),
                  controlPoint2: NSPoint(x: x + 2.6, y: size.height / 2 + 1.6))
        nub.close()
        nub.fill()
    }

    /// Заливка по уровню заряда. Возвращает её правый край: по нему метка
    /// состояния решает, где её выбивать из заливки, а где рисовать поверх.
    @discardableResult
    private static func drawFill(percentage: Int) -> CGFloat {
        let track = body.insetBy(dx: fillInset, dy: fillInset)
        let level = CGFloat(min(max(percentage, 0), 100)) / 100
        guard level > 0 else { return track.minX }
        // Даже на одном проценте оставляем видимую полоску: пустой корпус
        // и корпус с остатком заряда — разные состояния.
        let width = max(track.width * level, 2)
        let rect = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6).fill()
        return rect.maxX
    }

    /// Метку рисуем в два приёма: внутри заливки выбиваем её «дыркой»,
    /// снаружи — обычной краской. Иначе на низком заряде метка исчезала бы
    /// вместе с заливкой, а на высоком сливалась бы с ней.
    private static func drawBadge(_ symbolName: String, fillMaxX: CGFloat) {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }

        // Метка живёт внутри корпуса: ограничиваем и по высоте, и по ширине —
        // иначе широкие символы (вилка) упираются в стенки.
        let maxHeight: CGFloat = 7
        let maxWidth: CGFloat = 9.5
        let scale = min(maxHeight / symbol.size.height, maxWidth / symbol.size.width, 1)
        let drawSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let rect = NSRect(x: body.midX - drawSize.width / 2,
                          y: body.midY - drawSize.height / 2,
                          width: drawSize.width, height: drawSize.height)

        symbol.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)

        guard fillMaxX < rect.maxX else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: fillMaxX, y: 0,
                                  width: size.width - fillMaxX, height: size.height)).setClip()
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}
