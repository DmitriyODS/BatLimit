import Foundation

/// Набор SMC-ключей, которым управляется зарядка. Apple сменила его на новых машинах.
public enum ChargingAPI: String {
    case tahoe    = "CHTE/CHIE"   // M4 и новее, macOS Sequoia/Tahoe
    case legacy   = "CH0B/CH0C"   // M1/M2/M3
    case unknown  = "не найден"
}

/// Единственное место, которое пишет в SMC. Запись требует root, чтение — нет.
public final class ChargingController {
    private let smc: SMC
    public let api: ChargingAPI

    public init() throws {
        smc = try SMC()
        if smc.exists("CHTE") {
            api = .tahoe
        } else if smc.exists("CH0B") {
            api = .legacy
        } else {
            api = .unknown
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
        case .unknown:
            throw SMCError.badKey("на этой машине не найден ни CHTE, ни CH0B")
        }
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
        case .unknown:
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
