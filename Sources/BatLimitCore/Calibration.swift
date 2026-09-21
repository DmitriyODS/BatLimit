import Foundation

/// Отмена калибровочной зарядки macOS.
///
/// Раз в несколько дней powerd решает зарядить батарею до 100 %, чтобы
/// датчик заряда уточнил себя, и на это время снимает лимит зарядки — свой
/// и наш. Помешать самой зарядке нечем: политику лимита с флагом
/// `noChargeToFull`, которую powerd при калибровке не снимает, принимают
/// только клиенты с правом `com.apple.private.iokit.soc-limit`, а SMC-ключ
/// `CHLS`, которым лимит уходит в контроллер питания, закрыт правом
/// `com.apple.private.applesmc.user-access` — их Apple выдаёт только своим
/// программам.
///
/// Зато видно, из чего powerd делает вывод. Своё состояние он держит
/// в обычном домене настроек `com.apple.powerd.batterygauging` (файл
/// `/var/root/Library/Preferences/com.apple.powerd.batterygauging.plist`)
/// и читает его при запуске. В словаре `batteryGaugingMitigationInfo` лежат
/// даты, по которым он и принимает решение:
///
/// - `lastDOD0Update` старше 3 суток   → «Last DOD0 change N days ago — charge to full»;
/// - `lastQMaxUpdate` старше 14 суток  → «Last QMax Change: N days ago; charge to full now»;
/// - `lastFullChargeDate` старше 30 суток → «Last full charge date was N days ago, try and charge to full»;
/// - сама проверка — не чаще раза в 12 часов (`lastChargeToFullCheckDate`).
///
/// Значит, чтобы калибровка не начиналась, достаточно сдвинуть эти даты на
/// «сейчас» и дать powerd перечитать их: на лету он их не перечитывает, свои
/// значения держит в памяти, поэтому службу приходится перезапускать — так же,
/// как это делает установка обновлений системы. После перезапуска powerd
/// видит свежие даты, отказывается от калибровки и снимает запрос: проверено
/// на M4 Pro с macOS 27 — флаг `chargingtofulloverride` гаснет за секунды.
///
/// Даты powerd переписывает сам, когда датчик действительно обновит DOD0 или
/// Qmax на полном заряде, так что наша правка живёт ровно до следующей
/// настоящей полной зарядки и ничего в батарее не подменяет.
public enum CalibrationControl {
    private static let domain = "com.apple.powerd.batterygauging" as CFString
    private static let infoKey = "batteryGaugingMitigationInfo" as CFString
    private static let packsKey = "batteryPackData"
    private static let fullChargeKey = "lastFullChargeDate"
    /// Даты, из которых powerd считает возраст калибровки.
    private static let packDateKeys = ["lastDOD0Update", "lastQMaxUpdate", "lastQualQMaxDate"]

    /// Насколько отодвигаем даты назад, когда калибровку просят начать:
    /// порог по DOD0 — трое суток, берём с запасом.
    private static let overdue: TimeInterval = 5 * 24 * 3600
    private static let checkKey = "lastChargeToFullCheckDate"

    /// Есть ли на этой версии macOS то, чем мы управляем: свой разбор дат
    /// powerd держит в настройках, и если их там нет — механизм другой,
    /// и лезть в него вслепую нельзя.
    public static var isAvailable: Bool {
        guard let info = CFPreferencesCopyAppValue(infoKey, domain) as? [String: Any],
              let packs = info[packsKey] as? [String: Any] else { return false }
        return packs.values.contains { pack in
            guard let pack = pack as? [String: Any] else { return false }
            return packDateKeys.contains { pack[$0] is Date }
        }
    }

    /// Отодвигает повод для калибровки и перезапускает powerd.
    /// Требует root: домен принадлежит пользователю root.
    public static func postpone(now: Date = Date()) throws {
        try shiftDates(to: now, check: nil)
    }

    /// Наоборот: делает даты просроченными, чтобы powerd начал калибровку
    /// прямо сейчас. Дату последней проверки сдвигаем тоже — иначе powerd
    /// вправе отложить решение (он проверяет не чаще раза в 12 часов).
    public static func requestNow(now: Date = Date()) throws {
        let past = now.addingTimeInterval(-overdue)
        try shiftDates(to: past, check: past)
    }

    private static func shiftDates(to when: Date, check: Date?) throws {
        guard var info = CFPreferencesCopyAppValue(infoKey, domain) as? [String: Any] else {
            throw CalibrationError.noState
        }

        var packs = info[packsKey] as? [String: Any] ?? [:]
        var touched = 0
        for (serial, raw) in packs {
            guard var pack = raw as? [String: Any] else { continue }
            for key in packDateKeys where pack[key] is Date {
                pack[key] = when
                touched += 1
            }
            packs[serial] = pack
        }
        // Ни одной даты — значит структура не та, что мы знаем: лучше ничего
        // не трогать, чем записать в чужие настройки мусор.
        guard touched > 0 else { throw CalibrationError.noState }

        info[packsKey] = packs
        if info[fullChargeKey] is Date { info[fullChargeKey] = when }
        if let check, info[checkKey] is Date { info[checkKey] = check }

        CFPreferencesSetAppValue(infoKey, info as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw CalibrationError.writeFailed }

        try restartPowerd()
    }

    /// powerd читает своё состояние только при запуске, поэтому после правки
    /// дат его нужно перезапустить. launchd поднимает его сразу же.
    private static func restartPowerd() throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["kickstart", "-k", "system/com.apple.powerd"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw CalibrationError.restartFailed("\(error)")
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw CalibrationError.restartFailed("launchctl вернул \(task.terminationStatus)")
        }
    }
}

public enum CalibrationError: Error, CustomStringConvertible {
    case noState
    case writeFailed
    case restartFailed(String)

    public var description: String {
        switch self {
        case .noState:
            return "в настройках powerd нет состояния калибровки — отменять нечего"
        case .writeFailed:
            return "не удалось записать настройки powerd — нужен root"
        case .restartFailed(let why):
            return "не удалось перезапустить powerd: \(why)"
        }
    }
}
