import Foundation
import IOKit

/// Пригодность машины для BatLimit.
///
/// Проверяем до установки службы, а не после: на Intel-маке и на десктопе без
/// батареи LaunchDaemon с правами root ставить незачем, а пароль администратора
/// спрашивать тем более. Один и тот же ответ используют приложение (перед
/// установкой), CLI (`batlimit check`) и установщик с образа.
public struct SystemCheck {
    /// Идентификатор модели, например `Mac16,8`.
    public let modelIdentifier: String
    /// Процессор, например `Apple M4 Pro`.
    public let chip: String
    /// Версия macOS, например `26.6.2`.
    public let osVersion: String
    public let isAppleSilicon: Bool
    public let hasBattery: Bool
    public let api: ChargingAPI
    public let hasMagSafeLED: Bool

    /// Ниже этой версии приложение не собирается (см. `Package.swift`).
    public static let minimumOSMajor = 13

    public static func run() -> SystemCheck {
        // Определять Apple Silicon по `uname -m` нельзя: под Rosetta там x86_64.
        let arm = sysctlInt("hw.optional.arm64") == 1
        let os = ProcessInfo.processInfo.operatingSystemVersion

        // Читать SMC можно и без root, поэтому набор ключей виден заранее.
        let controller = try? ChargingController()

        return SystemCheck(
            modelIdentifier: sysctlString("hw.model") ?? "неизвестно",
            chip: sysctlString("machdep.cpu.brand_string") ?? "неизвестно",
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            isAppleSilicon: arm,
            hasBattery: serviceExists("AppleSmartBattery"),
            api: controller?.api ?? .unknown,
            hasMagSafeLED: controller?.hasMagSafeLED ?? false)
    }

    /// Пусто — машина подходит. Иначе по одной причине на элемент.
    public var problems: [String] {
        var found: [String] = []
        if !isAppleSilicon {
            found.append("нужен Mac на Apple Silicon (M1 и новее), здесь \(chip)")
        }
        if osMajor < SystemCheck.minimumOSMajor {
            found.append("нужна macOS \(SystemCheck.minimumOSMajor) или новее, "
                + "установлена \(osVersion)")
        }
        if !hasBattery {
            found.append("в этом Mac нет встроенной батареи — ограничивать нечего")
        }
        // Проверяем последним: на Intel и на десктопе ключей не будет по любой
        // из причин выше, и дублировать одну и ту же новость незачем.
        if found.isEmpty && api == .unknown {
            found.append("нет ни SMC-ключей CHTE/CH0B, ни лимита зарядки macOS — "
                + "управлять зарядкой на этой машине нечем")
        }
        return found
    }

    public var isSupported: Bool { problems.isEmpty }

    /// Человекочитаемая сводка: сначала что за машина, потом вердикт.
    public var summary: String {
        var lines = [
            "Модель:  \(modelIdentifier)",
            "Процессор: \(chip)",
            "macOS:   \(osVersion)",
            "Батарея: \(hasBattery ? "есть" : "нет")",
            "Управление зарядкой: \(api.rawValue)",
            "Индикатор MagSafe: \(hasMagSafeLED ? "есть" : "нет")",
        ]
        if isSupported {
            lines.append("")
            lines.append("Этот Mac поддерживается.")
        } else {
            lines.append("")
            lines.append("BatLimit не будет работать на этом Mac:")
            lines.append(contentsOf: problems.map { "  · \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private var osMajor: Int {
        Int(osVersion.split(separator: ".").first.map(String.init) ?? "0") ?? 0
    }

    // MARK: - Внутреннее

    private static func serviceExists(_ name: String) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching(name))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
