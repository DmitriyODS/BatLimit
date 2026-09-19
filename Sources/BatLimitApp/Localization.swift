import Foundation
import BatLimitCore

// Тексты интерфейса живут в Localizable.strings (ru и en). В коде остаются
// только ключи: строку подбирает система по языку пользователя.

/// Короткое имя для `NSLocalizedString`: обращений к нему в интерфейсе сотни,
/// и полная форма съедала бы строку целиком.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Та же выборка, но с подстановкой. Первый аргумент обязателен — иначе вызов
/// `L("ключ")` подошёл бы обеим формам и компилятор не смог бы выбрать.
func L(_ key: String, _ first: CVarArg, _ rest: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: [first] + rest)
}

extension PhaseKind {
    /// Слова к причине подбираем сами: служба присылает только её код.
    func localized(plugged: Bool, low: Int, high: Int) -> String {
        let source = plugged ? L("source.ac") : L("source.battery")
        switch self {
        case .noController:     return L("phase.noController")
        case .releasing:        return L("phase.releasing", source)
        case .inhibiting:       return L("phase.inhibiting", source)
        case .systemLimitHolds: return L("phase.systemLimitHolds")
        case .systemCalibrating: return L("phase.systemCalibrating")
        case .inhibitIgnored:   return L("phase.inhibitIgnored")
        case .oneShot:          return L("phase.oneShot", source, high)
        case .notManaging:      return L("phase.notManaging", source)
        case .blocked:          return L("phase.blocked", source)
        case .chargingToHigh:   return L("phase.chargingToHigh", source, high)
        case .waitingForLow:    return L("phase.waitingForLow", source, low)
        case .daemonStopped:    return L("phase.daemonStopped")
        }
    }
}

extension Status {
    /// Фаза для показа. У статуса, написанного старой службой, кода фазы нет —
    /// тогда показываем её же русский текст, чтобы строка не опустела.
    var localizedPhase: String {
        phaseKind?.localized(plugged: isPluggedIn, low: low, high: high) ?? phase
    }
}

extension EnergyMode {
    var localizedName: String {
        switch self {
        case .automatic: return L("energy.automatic")
        case .low:       return L("energy.low")
        case .high:      return L("energy.high")
        }
    }
}
