import Foundation

/// Режим энергии macOS — тот же переключатель, что в «Настройки → Аккумулятор →
/// Режим энергии»: автоматически, экономия энергии, высокая производительность.
public enum EnergyMode: String, Codable, CaseIterable {
    case automatic
    case low
    case high

    /// Значение ключа `powermode` у `pmset`.
    public var pmsetValue: Int {
        switch self {
        case .automatic: return 0
        case .low:       return 1
        case .high:      return 2
        }
    }

    public var humanReadable: String {
        switch self {
        case .automatic: return "автоматически"
        case .low:       return "экономия энергии"
        case .high:      return "высокая производительность"
        }
    }
}

/// Источник питания в терминах настроек powerd.
public enum PowerSourceKey: String, CaseIterable {
    case battery = "Battery Power"
    case ac      = "AC Power"

    /// Ключ `pmset`, которым правят настройки только этого источника.
    var pmsetFlag: String {
        switch self {
        case .battery: return "-b"
        case .ac:      return "-c"
        }
    }

    public var humanReadable: String {
        switch self {
        case .battery: return "от батареи"
        case .ac:      return "от сети"
        }
    }
}

/// Режим энергии для каждого источника питания по отдельности — так он
/// устроен и в macOS: в Настройках у батареи и у адаптера свои переключатели.
public struct EnergyModePair: Codable, Equatable {
    public var battery: EnergyMode?
    public var ac: EnergyMode?

    public init(battery: EnergyMode? = nil, ac: EnergyMode? = nil) {
        self.battery = battery
        self.ac = ac
    }

    public subscript(source: PowerSourceKey) -> EnergyMode? {
        get { source == .battery ? battery : ac }
        set {
            switch source {
            case .battery: battery = newValue
            case .ac:      ac = newValue
            }
        }
    }

    public var isEmpty: Bool { battery == nil && ac == nil }
}

/// Чтение и запись режима энергии.
///
/// Настройки питания живут не в обычном plist-домене: powerd отдаёт их через
/// IOKit (`IOPMCopyPMPreferences`), а правка через файл прошла бы мимо демона
/// и не применилась бы. Читать можно без прав, писать — только root, поэтому
/// запись делает служба, а приложение просит её через config.json.
///
/// Символы не объявлены в публичных заголовках IOKit, но экспортируются
/// фреймворком — берём их через `dlsym`, как это делает сам `pmset`.
public enum EnergyModes {
    /// Тристабильный ключ: 0 — автоматически, 1 — экономия, 2 — высокая
    /// производительность. Отдельный `HighPowerMode` остался от MacBook Pro 16",
    /// где высокая производительность появилась раньше общего переключателя.
    private static let modeKey = "LowPowerMode"
    private static let legacyHighKey = "HighPowerMode"

    private typealias CopyPreferences = @convention(c) () -> Unmanaged<CFMutableDictionary>?
    private typealias FeatureIsAvailable = @convention(c) (CFString, CFString?) -> DarwinBoolean

    private static let iokit: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let iokit, let address = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    private static func preferences() -> [String: Any]? {
        guard let copy = symbol("IOPMCopyPMPreferences", as: CopyPreferences.self) else { return nil }
        return copy()?.takeRetainedValue() as? [String: Any]
    }

    /// Режим, выставленный для конкретного источника питания.
    public static func current(source: PowerSourceKey) -> EnergyMode? {
        guard let settings = preferences()?[source.rawValue] as? [String: Any] else { return nil }
        if (settings[legacyHighKey] as? Int) == 1 { return .high }
        switch settings[modeKey] as? Int {
        case 0:  return .automatic
        case 1:  return .low
        case 2:  return .high
        default: return nil
        }
    }

    /// Режим для источника, от которого ноутбук работает прямо сейчас.
    public static func current(plugged: Bool) -> EnergyMode? {
        current(source: plugged ? .ac : .battery)
    }

    /// Режимы обоих источников разом.
    public static func current() -> EnergyModePair {
        EnergyModePair(battery: current(source: .battery), ac: current(source: .ac))
    }

    /// Поддерживает ли Mac высокую производительность на этом источнике.
    /// На машинах без неё powerd отвечает, что такой возможности нет, —
    /// пункт прячем, а не показываем кнопку, которая ничего не делает.
    public static func supportsHigh(source: PowerSourceKey) -> Bool {
        guard let available = symbol("IOPMFeatureIsAvailable", as: FeatureIsAvailable.self) else {
            return false
        }
        return available(legacyHighKey as CFString, source.rawValue as CFString).boolValue
    }

    public enum ApplyError: Error, CustomStringConvertible {
        case failed(String)

        public var description: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    /// Ставит режим для одного источника питания. Нужен root.
    ///
    /// Зовём `pmset`, а не пишем настройки сами: он переводит режим в ключи по
    /// правилам конкретной модели и уведомляет powerd, так что применяется всё
    /// сразу, без перезагрузки.
    ///
    /// Объединённый ключ `powermode` появился не сразу — на macOS 13 у `pmset`
    /// есть только пара отдельных ключей. Поэтому при отказе повторяем ими.
    public static func apply(_ mode: EnergyMode, source: PowerSourceKey) throws {
        let flag = source.pmsetFlag
        let highKey = legacyHighKey.lowercased()
        do {
            try pmset([flag, "powermode", "\(mode.pmsetValue)"])
        } catch {
            switch mode {
            case .automatic:
                try pmset([flag, "lowpowermode", "0"])
                try? pmset([flag, highKey, "0"])
            case .low:
                try? pmset([flag, highKey, "0"])
                try pmset([flag, "lowpowermode", "1"])
            case .high:
                try? pmset([flag, "lowpowermode", "0"])
                try pmset([flag, highKey, "1"])
            }
        }
    }

    private static func pmset(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw ApplyError.failed("не удалось запустить pmset: \(error)")
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ApplyError.failed(text.isEmpty
                ? "pmset \(arguments.joined(separator: " ")) вернул код \(process.terminationStatus)"
                : text)
        }
    }
}
