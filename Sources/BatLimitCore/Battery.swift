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
    /// Читает AppleSmartBattery из IORegistry. Root не нужен.
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

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

        // Температура хранится в сотых долях градуса.
        let temperature = (props["Temperature"] as? Int).map { Double($0) / 100 }

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
                           maxCapacity: (props["NominalChargeCapacity"] as? Int)
                               ?? (props["AppleRawMaxCapacity"] as? Int),
                           designCapacity: props["DesignCapacity"] as? Int,
                           temperature: temperature)
    }
}
