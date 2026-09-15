import Foundation

public enum Paths {
    public static let label   = "com.dmitriy.batlimit"
    public static let dir     = "/Library/Application Support/BatLimit"
    public static let config  = dir + "/config.json"
    public static let status  = dir + "/status.json"
    public static let version = dir + "/installed-version"
    /// Лимит зарядки macOS, который стоял до BatLimit (см. `SystemChargeLimitBackup`).
    public static let systemLimitBackup = dir + "/macos-charge-limit"
    /// Демон лежит вне бандла: LaunchDaemon под root не должен запускать
    /// бинарник из каталога, доступного на запись пользователю.
    public static let daemon  = "/Library/PrivilegedHelperTools/" + label
    public static let plist   = "/Library/LaunchDaemons/\(label).plist"
    public static let log     = "/var/log/batlimit.log"
}

public enum Mode: String, Codable, CaseIterable {
    case off    // не вмешиваемся, зарядка идёт как обычно
    case hold   // не заряжать, пока не скажут иначе
    case auto   // держать заряд в коридоре low…high

    public var humanReadable: String {
        switch self {
        case .off:  return "выключено"
        case .hold: return "не заряжать"
        case .auto: return "авто"
        }
    }
}

/// Что хочет пользователь. Пишут CLI и меню, читает демон.
public struct Config: Codable, Equatable {
    public var mode: Mode
    public var low: Int          // нижний порог авто-режима
    public var high: Int         // верхний порог: до скольки заряжать
    public var chargeNow: Bool   // разовая зарядка до `high`, потом флаг сбрасывается
    public var magsafeLED: Bool  // подсвечивать разъём MagSafe зелёным, когда зарядка удержана

    public static let fallback = Config(mode: .off, low: 30, high: 80,
                                        chargeNow: false, magsafeLED: true)

    public init(mode: Mode, low: Int, high: Int, chargeNow: Bool, magsafeLED: Bool = true) {
        self.mode = mode
        self.low = low
        self.high = high
        self.chargeNow = chargeNow
        self.magsafeLED = magsafeLED
        clamp()
    }

    /// Старые конфиги поля не содержат — считаем подсветку включённой.
    enum CodingKeys: String, CodingKey {
        case mode, low, high, chargeNow, magsafeLED
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .off
        low = try c.decodeIfPresent(Int.self, forKey: .low) ?? 30
        high = try c.decodeIfPresent(Int.self, forKey: .high) ?? 80
        chargeNow = try c.decodeIfPresent(Bool.self, forKey: .chargeNow) ?? false
        magsafeLED = try c.decodeIfPresent(Bool.self, forKey: .magsafeLED) ?? true
        clamp()
    }

    /// Значения приходят из файла, который может править любой админ, — не доверяем.
    public mutating func clamp() {
        low = min(max(low, 5), 95)
        high = min(max(high, low + 5), 100)
    }

    public static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: Paths.config),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return .fallback
        }
        cfg.clamp()
        return cfg
    }

    /// Атомарная запись: пишем во временный файл рядом и переименовываем,
    /// чтобы демон никогда не прочитал половину файла.
    public func save() throws {
        var copy = self
        copy.clamp()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(copy)
        let tmp = Paths.config + ".tmp\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        // 664: демон под root читает, админ из GUI/CLI пишет.
        try? FileManager.default.setAttributes([.posixPermissions: 0o664],
                                               ofItemAtPath: tmp)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: Paths.config),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    }
}

/// Что происходит на самом деле. Пишет только демон.
public struct Status: Codable {
    public var percentage: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var inhibited: Bool          // зарядка действительно заблокирована нами
    /// Команда контроллеру отправлена, но он её ещё не применил. Контроллер
    /// перечитывает ключ раз в ~45–50 с, поэтому окно расхождения нормально.
    /// Optional — чтобы новый демон читал status.json, написанный старым.
    public var settling: Bool?
    public var systemLimitActive: Bool  // зарядку держит системный лимит macOS
    public var mode: Mode
    public var low: Int
    public var high: Int
    public var chargeNow: Bool
    public var phase: String            // человекочитаемое «что сейчас делаем»
    public var api: String
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    public var error: String?
    public var updatedAt: Date

    public init(percentage: Int, isCharging: Bool, isPluggedIn: Bool, inhibited: Bool,
                settling: Bool, systemLimitActive: Bool, mode: Mode, low: Int, high: Int,
                chargeNow: Bool, phase: String, api: String, minutesRemaining: Int?,
                cycleCount: Int?, error: String?, updatedAt: Date) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.inhibited = inhibited
        self.settling = settling
        self.systemLimitActive = systemLimitActive
        self.mode = mode
        self.low = low
        self.high = high
        self.chargeNow = chargeNow
        self.phase = phase
        self.api = api
        self.minutesRemaining = minutesRemaining
        self.cycleCount = cycleCount
        self.error = error
        self.updatedAt = updatedAt
    }

    /// Демон считается живым, если обновлял статус недавно.
    public var isFresh: Bool { Date().timeIntervalSince(updatedAt) < 30 }

    public static func load() -> Status? {
        guard let data = FileManager.default.contents(atPath: Paths.status) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Status.self, from: data)
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let tmp = Paths.status + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: tmp)
        _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: Paths.status),
                                                  withItemAt: URL(fileURLWithPath: tmp))
    }
}
