import Foundation

/// Чем управляется зарядка. Apple меняла рычаг между поколениями и версиями macOS.
public enum ChargingAPI: String {
    case tahoe      = "CHTE/CHIE"     // M4 и новее, macOS Sequoia/Tahoe
    case legacy     = "CH0B/CH0C"     // M1/M2/M3
    case macOSLimit = "лимит macOS"   // macOS 27: запрета в SMC больше нет, см. SystemChargeLimit
    case unknown    = "не найден"
}

/// Единственное место, которое пишет в SMC. Запись требует root, чтение — нет.
public final class ChargingController {
    private let smc: SMC
    public let api: ChargingAPI
    /// Есть только при `api == .macOSLimit`: там зарядка управляется потолком,
    /// а не запретом, и служба работает с ним напрямую.
    public let systemLimit: SystemChargeLimit?

    public init() throws {
        smc = try SMC()
        if smc.exists("CHTE") {
            api = .tahoe
            systemLimit = nil
        } else if smc.exists("CH0B") {
            api = .legacy
            systemLimit = nil
        } else if let limit = SystemChargeLimit() {
            api = .macOSLimit
            systemLimit = limit
        } else {
            api = .unknown
            systemLimit = nil
        }
    }

    /// Разрешить (`true`) или запретить (`false`) зарядку батареи.
    /// При запрете ноутбук продолжает работать от адаптера, батарея не заряжается.
    public func setChargingAllowed(_ allowed: Bool) throws {
        switch api {
        case .tahoe:
            try smc.write("CHTE", allowed ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00])
        case .legacy:
            let v: UInt8 = allowed ? 0x00 : 0x02
            try smc.write("CH0B", [v])
            try smc.write("CH0C", [v])
        case .macOSLimit, .unknown:
            throw SMCError.badKey("на этой машине не найден ни CHTE, ни CH0B")
        }
    }

    /// Заставляет контроллер заряда пересмотреть решение прямо сейчас.
    ///
    /// Контроллер применяет новый лимит в начале сессии зарядки, а внутри
    /// идущей может тянуть до следующего процента. Короткое отключение
    /// адаптера ключом `CHIE` (`08` — адаптер не используется) начинает новую
    /// сессию: на M4 Pro с macOS 27 зарядка останавливается в пределах
    /// нескольких секунд. Две секунды ноутбук работает от батареи.
    public func nudgeCharger() throws {
        try smc.write("CHIE", [0x08])
        defer { try? smc.write("CHIE", [0x00]) }
        sleep(2)
    }

    /// Адаптер отключён ключом `CHIE` — например, служба упала посреди
    /// `nudgeCharger`. Без сброса ноутбук так и остался бы на батарее.
    public func resetAdapterIfDisabled() -> Bool {
        guard let value = try? smc.read("CHIE").first, value != 0x00 else { return false }
        return (try? smc.write("CHIE", [0x00])) != nil
    }

    /// Что сейчас записано в SMC-ключе.
    ///
    /// Это отправленная контроллеру команда, а не факт остановки зарядки:
    /// контроллер перечитывает ключ только на своей периодической переоценке
    /// (на M4 — раз в 45–50 с), поэтому сразу после записи ключ уже взведён,
    /// а зарядка ещё идёт на полном токе. Факт смотри по
    /// `BatteryInfo.ourInhibitActive` — биту 55 в `NotChargingReason`.
    public func isInhibitRequested() throws -> Bool {
        switch api {
        case .tahoe:
            return try smc.read("CHTE").first.map { $0 != 0x00 } ?? false
        case .legacy:
            return try smc.read("CH0B").first.map { $0 != 0x00 } ?? false
        case .macOSLimit, .unknown:
            throw SMCError.badKey("на этой машине не найден ни CHTE, ни CH0B")
        }
    }

    /// Цвета индикатора MagSafe (SMC-ключ ACLC).
    public enum LED: UInt8 {
        case auto   = 0x00   // цветом управляет система
        case off    = 0x01
        case green  = 0x03
        case orange = 0x04
    }

    /// Есть ли на этой машине разъём MagSafe со светодиодом.
    public var hasMagSafeLED: Bool { smc.exists("ACLC") }

    public func setLED(_ color: LED) throws {
        try smc.write("ACLC", [color.rawValue])
    }

    public func currentLED() -> LED? {
        guard let raw = try? smc.read("ACLC").first else { return nil }
        return LED(rawValue: raw)
    }

    /// Диагностика: сырое значение любого ключа.
    public func rawRead(_ key: String) throws -> (bytes: [UInt8], type: String) {
        (try smc.read(key), try smc.keyInfo(key).type)
    }
}
