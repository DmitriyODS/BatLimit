import Foundation
import IOKit

public struct BatteryInfo {
    public let percentage: Int
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let notChargingReason: UInt64
    public let minutesToEmpty: Int?
    public let minutesToFull: Int?
    public let cycleCount: Int?
    public let maxCapacity: Int?      // мА·ч, сглаженная полная ёмкость (как у macOS)
    public let designCapacity: Int?   // мА·ч, заводская ёмкость
    public let temperature: Double?   // °C

    /// Износ батареи: сколько осталось от заводской ёмкости.
    public var health: Double? {
        guard let max = maxCapacity, let design = designCapacity, design > 0 else { return nil }
        return Double(max) / Double(design) * 100
    }

    /// Зарядку блокирует системный лимит macOS («до 80%»), а не мы. Бит 24.
    public var systemLimitActive: Bool { notChargingReason & 0x0000_0000_0100_0000 != 0 }
    /// Зарядку блокируем мы через CHTE. Бит 55.
    public var ourInhibitActive: Bool { notChargingReason & 0x0080_0000_0000_0000 != 0 }
}

public enum Battery {
    /// Сырой словарь свойств AppleSmartBattery. Root не нужен.
    public static func properties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }

    /// Читает AppleSmartBattery из IORegistry. Root не нужен.
    public static func read() -> BatteryInfo? {
        guard let props = properties() else { return nil }

        let percentage = props["CurrentCapacity"] as? Int ?? 0
        let isCharging = props["IsCharging"] as? Bool ?? false
        let plugged = props["ExternalConnected"] as? Bool ?? false

        var reason: UInt64 = 0
        if let charger = props["ChargerData"] as? [String: Any],
           let r = charger["NotChargingReason"] as? UInt64 {
            reason = r
        }

        // 65535 и 0 — «неизвестно»
        func minutes(_ key: String) -> Int? {
            guard let v = props[key] as? Int, v > 0, v < 65535 else { return nil }
            return v
        }

        // В macOS 27 ёмкости и температура пропали с верхнего уровня
        // AppleSmartBattery: ёмкости переехали в словарь `BatteryData`,
        // температуры в IORegistry нет вовсе. Сначала смотрим по-старому.
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func capacity(_ key: String) -> Int? {
            (props[key] as? Int) ?? (data[key] as? Int)
        }

        // Температура хранится в сотых долях градуса.
        let temperature = (props["Temperature"] as? Int).map { Double($0) / 100 }
            ?? smcTemperature()

        return BatteryInfo(percentage: percentage,
                           isCharging: isCharging,
                           isPluggedIn: plugged,
                           notChargingReason: reason,
                           minutesToEmpty: minutes("AvgTimeToEmpty"),
                           minutesToFull: minutes("AvgTimeToFull"),
                           cycleCount: props["CycleCount"] as? Int,
                           // macOS в «Об этом Mac» показывает NominalChargeCapacity —
                           // сглаженную оценку. AppleRawMaxCapacity это сырое
                           // показание газоанализатора: оно скачет на проценты
                           // от температуры и заряда, и пугает пользователя.
                           maxCapacity: capacity("NominalChargeCapacity")
                               ?? (props["AppleRawMaxCapacity"] as? Int)
                               ?? capacity("FullChargeCapacity"),
                           designCapacity: capacity("DesignCapacity"),
                           temperature: temperature)
    }

    /// Соединение с SMC держим открытым: служба читает батарею каждую секунду.
    private static let smc = try? SMC()

    /// Температура батареи из SMC-ключа `TB0T` (°C, `flt `). Root не нужен.
    private static func smcTemperature() -> Double? {
        guard let bytes = try? smc?.read("TB0T"), bytes.count == 4 else { return nil }
        // Числа типа `flt ` лежат little-endian, в отличие от остальных
        // значений SMC.
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let celsius = Double(Float(bitPattern: bits))
        guard celsius.isFinite, celsius > -40, celsius < 120 else { return nil }
        return celsius
    }
}
