import Foundation

/// Чем управляется зарядка. Apple меняла рычаг между поколениями и версиями macOS.
public enum ChargingAPI: String {
    case tahoe         = "CHTE/CHIE"        // M4 и новее, macOS Sequoia/Tahoe
    case legacy        = "CH0B/CH0C"        // M1/M2/M3
    case macOSLimit    = "лимит macOS"      // macOS 27: запрета в SMC больше нет, см. SystemChargeLimit
    case firmwareLimit = "bfD0/bfE0/bfF0"   // macOS 15.8+: лимит прошивки, см. FirmwareLimit
    case unknown       = "не найден"
}

/// Коридор заряда, который держит сама прошивка SMC.
///
/// Прошивка `20457.x` (её ставят и обновления macOS 15.8, и 26.7, и 27)
/// убрала запрет зарядки `CHTE`/`CH0B`. Осталась замена — лимит прошивки:
/// `bfF0` включает его (`00` — выключен, `02` — включён), `bfD0` — верхний
/// порог, `bfE0` — порог, ниже которого зарядка возобновится. Пороги — `ui32`
/// в процентах, little-endian, как и прочие числа SMC на Apple Silicon.
///
/// На macOS 27 драйвер AppleSMC пускает к этим ключам только программы
/// с правом `com.apple.private.iokit.soc-limit`, а на Sequoia — любого root.
///
/// Проверено на M4 (MacBook Air, macOS 15.8.1, mBoot-20457.1.29): коридор
/// на текущем заряде останавливает зарядку через ~60 с, ноутбук идёт от сети,
/// ток батареи — ноль, даже когда заряд на процент выше порога. Признак тот же,
/// что у `CHTE`: бит 55 в `NotChargingReason`. После выключения зарядка
/// возобновляется через ~20 с.
public struct FirmwareLimit: Equatable {
    public var upper: Int
    public var lower: Int

    public init(upper: Int, lower: Int) {
        self.upper = upper
        self.lower = lower
    }

    /// На сколько ниже верхнего порога зарядка возобновится. Узкий коридор —
    /// чтобы заряд не гулял, но и не впритык, чтобы контроллер не дёргался
    /// на каждом колебании показаний. Столько же ставит BatteryControl (80/78).
    public static let band = 2

    /// Ниже не опускаемся: меню BatLimit ниже 20 % порогов не предлагает.
    public static let minimum = 10

    /// Коридор с верхним порогом `upper` и нижним на `band` ниже.
    public static func holding(at upper: Int) -> FirmwareLimit {
        let top = min(max(upper, minimum), 100)
        return FirmwareLimit(upper: top, lower: top - band)
    }
}

public enum FirmwareLimitError: Error, CustomStringConvertible {
    case readbackMismatch(key: String, expected: [UInt8], got: [UInt8]?)

    public var description: String {
        switch self {
        case .readbackMismatch(let key, let expected, let got):
            let hex = { (b: [UInt8]) in b.map { String(format: "%02x", $0) }.joined(separator: " ") }
            return "SMC-ключ \(key): записали \(hex(expected)), прочитали \(got.map(hex) ?? "ничего")"
        }
    }
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
        // Нулевой размер — заглушка: на новой прошивке ключ остаётся в таблице,
        // но данных за ним нет.
        if smc.hasData("CHTE") {
            api = .tahoe
            systemLimit = nil
        } else if smc.hasData("CH0B") {
            api = .legacy
            systemLimit = nil
        } else if let limit = SystemChargeLimit() {
            // Где есть лимит macOS, лимитом прошивки распоряжается powerd —
            // писать туда же самим значило бы с ним спорить.
            api = .macOSLimit
            systemLimit = limit
        } else if ChargingController.firmwareLimitReadable(smc) {
            api = .firmwareLimit
            systemLimit = nil
        } else {
            api = .unknown
            systemLimit = nil
        }
    }

    /// Ключи лимита прошивки есть и читаются. Где их закрыл драйвер (macOS 27),
    /// уже запрос описания ключа кончается `kIOReturnNotPrivileged`.
    private static func firmwareLimitReadable(_ smc: SMC) -> Bool {
        guard (try? smc.read("bfF0"))?.count == 1 else { return false }
        return ["bfD0", "bfE0"].allSatisfy { (try? smc.keyInfo($0))?.size == 4 }
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
        case .macOSLimit, .firmwareLimit, .unknown:
            throw SMCError.badKey("на этой машине не найден ни CHTE, ни CH0B")
        }
    }

    // MARK: - Лимит прошивки (api == .firmwareLimit)

    /// Действующий лимит прошивки; `nil`, если он выключен или не читается.
    public func firmwareLimit() -> FirmwareLimit? {
        guard let flag = try? smc.read("bfF0").first, flag != 0x00,
              let upper = try? smc.read("bfD0"), let lower = try? smc.read("bfE0")
        else { return nil }
        return FirmwareLimit(upper: Int(ChargingController.fromLE32(upper)),
                             lower: Int(ChargingController.fromLE32(lower)))
    }

    /// Выставляет коридор. Требует root.
    ///
    /// Порядок — выключить, верхний порог, нижний, включить: пока пороги
    /// пишутся, лимит не действует, и прошивка не увидит полузаписанного
    /// коридора. Каждая запись сверяется чтением; при любом расхождении лимит
    /// выключается — лучше обычная зарядка, чем неизвестно какой коридор.
    public func setFirmwareLimit(_ limit: FirmwareLimit) throws {
        do {
            try writeVerified("bfF0", [0x00])
            try writeVerified("bfD0", ChargingController.toLE32(UInt32(limit.upper)))
            try writeVerified("bfE0", ChargingController.toLE32(UInt32(max(limit.lower, 0))))
            try writeVerified("bfF0", [0x02])
        } catch {
            try? smc.write("bfF0", [0x00])
            throw error
        }
    }

    /// Выключает лимит прошивки и обнуляет пороги — так было до BatLimit.
    public func clearFirmwareLimit() throws {
        try writeVerified("bfF0", [0x00])
        try writeVerified("bfD0", ChargingController.toLE32(0))
        try writeVerified("bfE0", ChargingController.toLE32(0))
    }

    private func writeVerified(_ key: String, _ bytes: [UInt8]) throws {
        try smc.write(key, bytes)
        let back = try? smc.read(key)
        guard back == bytes else {
            throw FirmwareLimitError.readbackMismatch(key: key, expected: bytes, got: back)
        }
    }

    private static func toLE32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)]
    }

    private static func fromLE32(_ b: [UInt8]) -> UInt32 {
        b.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
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
        case .macOSLimit, .firmwareLimit, .unknown:
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
