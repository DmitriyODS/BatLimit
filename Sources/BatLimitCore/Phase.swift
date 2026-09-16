import Foundation

/// Что служба делает с зарядкой прямо сейчас — в машиночитаемом виде.
///
/// Готовую фразу писать в статус мало: её показывает приложение, а оно может
/// быть на другом языке, чем служба. Служба называет причину, а слова к ней
/// подбирает тот, кто показывает — приложение из своих переводов, CLI из
/// `russian(_:)` ниже.
public enum PhaseKind: String, Codable {
    case noController      // ни SMC-ключей, ни лимита macOS — управлять нечем
    case releasing         // снимаем блокировку, контроллер ещё не применил
    case inhibiting        // выставляем блокировку, контроллер ещё не применил
    case systemLimitHolds  // зарядку держит чужой лимит macOS
    case inhibitIgnored    // запрет выставлен, а зарядка всё равно идёт
    case oneShot           // разовая зарядка до верхнего порога
    case notManaging       // режим «выключено»
    case blocked           // режим «не заряжать»
    case chargingToHigh    // авто-режим, фаза зарядки
    case waitingForLow     // авто-режим, ждём разряда
    case daemonStopped     // служба остановлена

    /// Русский текст фазы — для журнала службы и для CLI.
    public func russian(plugged: Bool, low: Int, high: Int) -> String {
        let source = plugged ? "от сети" : "от батареи"
        switch self {
        case .noController:     return "нечем управлять зарядкой"
        case .releasing:        return "\(source), снимаю блокировку — применяется…"
        case .inhibiting:       return "\(source), блокирую зарядку — применяется…"
        case .systemLimitHolds: return "от сети, зарядку держит системный лимит macOS"
        case .inhibitIgnored:   return "от сети, зарядка идёт, хотя запрет выставлен"
        case .oneShot:          return "\(source), заряжаю до \(high)% (разово)"
        case .notManaging:      return "\(source), не вмешиваюсь"
        case .blocked:          return "\(source), зарядка заблокирована"
        case .chargingToHigh:   return "\(source), заряжаю до \(high)%"
        case .waitingForLow:    return "\(source), жду разряда до \(low)%"
        case .daemonStopped:    return "служба остановлена"
        }
    }
}
