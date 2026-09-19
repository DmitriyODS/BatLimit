import Foundation
import notify

/// Калибровочная зарядка macOS до 100 %.
///
/// Раз в несколько дней powerd сам заряжает батарею до конца, чтобы уточнить
/// показания датчика заряда (перекалибровка Qmax/DOD0), если полной зарядки
/// давно не было. На это время он приостанавливает лимит зарядки — в его
/// журнале это `SOC limit policy suspend due to mitigation active:1`, — то
/// есть наш потолок временно ничего не значит: заряд всё равно пойдёт до 100 %.
///
/// Пока это идёт, вмешиваться бесполезно: переподключение адаптера (`CHIE`)
/// заряд не остановит, powerd тут же продолжит калибровку, и получится лишь
/// бесконечное мигание. Поэтому служба на это время отступает и честно
/// показывает, что батарею сейчас ведёт система.
///
/// Признак — состояние Darwin-уведомления
/// `com.apple.system.powersources.chargingtofulloverride`: powerd поднимает
/// его в 1 на время калибровки (постит строкой `posted
/// 'com.apple.system.powersources.chargingtofulloverride'`). Чтение состояния
/// прав не требует.
public enum SystemCalibration {
    private static let key = "com.apple.system.powersources.chargingtofulloverride"

    /// Токен регистрируем один раз: `notify_get_state` работает только по нему.
    private static let token: Int32? = {
        var t: Int32 = 0
        return notify_register_check(key, &t) == NOTIFY_STATUS_OK ? t : nil
    }()

    /// macOS сейчас ведёт калибровочную зарядку до 100 %.
    public static var chargingToFull: Bool {
        guard let token else { return false }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == NOTIFY_STATUS_OK else { return false }
        return state != 0
    }
}

/// Интерфейс `PowerUISmartChargeClient` из приватного PowerUI.framework —
/// ровно те методы, что нам нужны. Класс грузится в рантайме, поэтому объект
/// приводится к протоколу, а не к заголовку.
@objc private protocol PowerUIClient {
    @objc(initWithClientName:) func initWithClientName(_ name: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(isMCLCurrentlyEnabled:) func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt64
    @objc(enableMCL:) func enableMCL(_ error: NSErrorPointer) -> Bool
    @objc(getMCLLimitWithError:) func getMCLLimit(_ error: NSErrorPointer) -> UInt8
}

/// Лимит зарядки macOS («Ограничение заряда» в Настройках → Аккумулятор)
/// как рычаг управления, в том числе ниже 80 %.
///
/// На macOS 27 из SMC исчезли ключи запрета зарядки (`CHTE`, `CH0B`/`CH0C`).
/// Остался тот рычаг, которым пользуется сама система: политика
/// `manualChargeLimit` в powerd. Её выставляет `PowerUIAgent` (работает от root)
/// по значению `mclLimitValue` из своих настроек — домена
/// `com.apple.smartcharging.topoffprotection` пользователя root.
///
/// Через XPC (`setMCLLimit:`) агент примет только 80…100: диапазон проверяет
/// обработчик `client:setMCLLimit:withHandler:`, и больше нигде. А на
/// уведомление `com.apple.smartcharging.defaultschanged` агент выполняет
/// `loadDefaults` + `handleCallback`: перечитывает настройки и отдаёт лимит
/// в powerd без всякой проверки. Поэтому служба пишет значение прямо
/// в настройки агента и шлёт уведомление. powerd передаёт лимит
/// в `AppleSmartBatteryManager`, и заряд держится битом 24 в `NotChargingReason`.
///
/// Писать может только root: домен принадлежит пользователю root.
public final class SystemChargeLimit {
    public static let domain = "com.apple.smartcharging.topoffprotection"
    public static let changedNotification = "com.apple.smartcharging.defaultschanged"

    /// Ниже не опускаемся: система таких значений сама не выставляет,
    /// а меню BatLimit ниже 20 % порогов не предлагает.
    public static let minimum = 10

    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
    private static let limitKey = "mclLimitValue"
    private static let featureStateKey = "MCLFeatureState"
    /// «Зарядить до конца сейчас» из меню батареи: пока ключ есть, агент
    /// лимит не применяет.
    private static let tempDisabledKey = "MCLTempDisabledUntilDate"

    private let client: PowerUIClient

    /// `nil`, если PowerUI нет или ручной лимит на этой машине не поддерживается.
    public init?() {
        guard dlopen(SystemChargeLimit.frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        let object = unsafeBitCast(allocated, to: PowerUIClient.self).initWithClientName("batlimit")
        client = unsafeBitCast(object, to: PowerUIClient.self)
        guard client.isMCLSupported() else { return nil }
    }

    /// Лимит, который сейчас применяет агент. Спрашиваем по XPC у самого
    /// агента: значение в файле настроек ещё не значит, что агент его перечитал.
    public func agentLimit() -> Int? {
        var error: NSError?
        let value = client.getMCLLimit(&error)
        return error == nil ? Int(value) : nil
    }

    public var isEnabled: Bool {
        var error: NSError?
        return client.isMCLCurrentlyEnabled(&error) != 0 && error == nil
    }

    /// Пользователь временно снял лимит из меню батареи.
    public var isTemporarilyDisabled: Bool {
        CFPreferencesCopyAppValue(SystemChargeLimit.tempDisabledKey as CFString,
                                  SystemChargeLimit.domain as CFString) != nil
    }

    /// Выставляет лимит. Требует root.
    public func setLimit(_ percent: Int) throws {
        let value = min(max(percent, SystemChargeLimit.minimum), 100)
        let domain = SystemChargeLimit.domain as CFString

        // Если лимит в Настройках выключен, одно значение ничего не даст.
        // Сначала штатный путь, при отказе — флаг в тех же настройках.
        if !isEnabled {
            var error: NSError?
            _ = client.enableMCL(&error)
            if !isEnabled {
                CFPreferencesSetAppValue(SystemChargeLimit.featureStateKey as CFString,
                                         1 as CFNumber, domain)
            }
        }
        CFPreferencesSetAppValue(SystemChargeLimit.tempDisabledKey as CFString, nil, domain)
        CFPreferencesSetAppValue(SystemChargeLimit.limitKey as CFString, value as CFNumber, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw SystemChargeLimitError.writeFailed
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(SystemChargeLimit.changedNotification as CFString),
            nil, nil, true)
    }
}

public enum SystemChargeLimitError: Error, CustomStringConvertible {
    case writeFailed

    public var description: String {
        switch self {
        case .writeFailed:
            return "не удалось записать настройки PowerUIAgent (\(SystemChargeLimit.domain)) — нужен root"
        }
    }
}

/// Лимит, который стоял в системе до того, как BatLimit взял его под контроль.
/// Возвращаем его, когда отпускаем управление.
public enum SystemChargeLimitBackup {
    public static func load() -> Int? {
        guard let raw = try? String(contentsOfFile: Paths.systemLimitBackup, encoding: .utf8) else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Система сама ставит только 80…100. Если там осталось что-то ниже
    /// (например, после аварийной остановки чужой программы), вернём 80:
    /// меньшее значение пользователь не увидит и не сможет поменять в Настройках.
    public static func save(_ percent: Int) {
        let value = min(max(percent, 80), 100)
        try? "\(value)".write(toFile: Paths.systemLimitBackup, atomically: true, encoding: .utf8)
    }

    public static func remove() {
        try? FileManager.default.removeItem(atPath: Paths.systemLimitBackup)
    }
}
