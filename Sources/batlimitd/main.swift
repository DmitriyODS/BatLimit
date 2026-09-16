import Foundation
import BatLimitCore

// Демон batlimitd. Работает под root как LaunchDaemon, единственный, кто пишет в SMC.
// Пользовательские процессы (batlimit, BatLimitMenu) только кладут config.json
// и читают status.json — сами привилегий не имеют.

private let logTimestampFormatter = ISO8601DateFormatter()

private func log(_ message: String) {
    let ts = logTimestampFormatter.string(from: Date())
    print("[\(ts)] \(message)")
    fflush(stdout)
}

final class Daemon {
    private let controller: ChargingController

    /// Фаза авто-режима. true — заряжаем до `high`, false — ждём разряда до `low`.
    /// Хранение фазы между тиками и даёт гистерезис: в коридоре low…high
    /// направление не меняется, поэтому реле не дёргается на каждом проценте.
    private var phaseCharging = false

    /// Разовая зарядка по кнопке: зеркало `config.chargeNow`. Живёт до
    /// достижения `high`, до смены режима или пока пользователь не снимет флаг.
    private var oneShot = false

    /// Сколько ждём, пока контроллер применит команду, прежде чем перестать
    /// говорить «применяется». На M4 переоценка занимает 45–50 с, берём с запасом.
    private static let settleWindow: TimeInterval = 90

    /// Что мы просили у контроллера в прошлый раз и когда просьба изменилась.
    private var requestedInhibit: Bool?
    private var requestChangedAt = Date.distantPast

    private var lastMode: Mode?
    /// Последняя запись про разовую зарядку: если конфиг вдруг не пишется,
    /// одно и то же сообщение иначе уходило бы в лог каждую секунду.
    private var lastOneShotNote: String?
    private var lastLED: ChargingController.LED?
    /// Цвет, к которому мы клонимся, и с какого момента. Меняем не сразу:
    /// см. `applyLED`.
    private var pendingLED: ChargingController.LED?
    private var pendingLEDSince = Date.distantPast
    /// Сколько желаемый цвет должен продержаться, прежде чем его применять.
    private static let ledDebounce: TimeInterval = 5
    /// Режим энергии macOS. Перечитываем раз в несколько секунд: его меняют
    /// не только через нас, но и в Настройках, и в Пункте управления.
    private var energyMode: EnergyMode?
    private var lastEnergyModeRead = Date.distantPast
    private static let energyModeInterval: TimeInterval = 5
    private lazy var highPowerAvailable = EnergyModes.supportsHigh()
    private var lastHistoryWrite = Date.distantPast
    private var lastLogRotateCheck = Date.distantPast
    private var lastTrim = Date.distantPast
    private var lastStatusWrite = Date.distantPast
    private var lastWrittenStatus: String?
    private var lastError: String?

    // MARK: Лимит macOS (api == .macOSLimit)

    /// Потолок, на котором держим заряд, пока зарядка запрещена. Только
    /// опускается: подними его вслед за процентом — и контроллер, дозаряжая
    /// батарею на лишний процент при остановке, тянул бы его вверх бесконечно.
    private var holdCeiling: Int?
    /// Что записали в последний раз и когда.
    private var appliedLimit: Int?
    private var limitWrittenAt = Date.distantPast
    /// С какого момента факт расходится с решением и толкали ли уже контроллер
    /// за это расхождение — не чаще раза, иначе при упрямом контроллере
    /// адаптер отключался бы каждые 20 секунд.
    private var mismatchSince: Date?
    private var nudgedThisMismatch = false
    /// Решение, при котором писали лимит в последний раз, — для журнала.
    private var lastLimitAllowed: Bool?
    private var lastLimitCheck = Date.distantPast
    /// Сколько расхождение должно продержаться, прежде чем толкать контроллер.
    /// Сам он подхватывает новый лимит за ~10 с, а `IsCharging` на подключении
    /// адаптера на мгновение взводится и при удержанном заряде.
    private static let nudgeDelay: TimeInterval = 20
    /// Как часто сверяться с агентом: лимит могут поменять в Настройках.
    private static let limitCheckInterval: TimeInterval = 5

    init() throws {
        controller = try ChargingController()
        log("Запуск. Управление зарядкой: \(controller.api.rawValue)")
        switch controller.api {
        case .unknown:
            log("ВНИМАНИЕ: ни SMC-ключей, ни лимита macOS нет, управлять зарядкой не смогу")
        case .macOSLimit:
            let agent = controller.systemLimit?.agentLimit().map { "\($0)%" } ?? "не отвечает"
            log("Лимит macOS сейчас: \(agent)"
                + (SystemChargeLimitBackup.load().map { ", до BatLimit стоял \($0)%" } ?? ""))
            if controller.resetAdapterIfDisabled() {
                log("Адаптер был отключён ключом CHIE — включён обратно")
            }
        case .tahoe, .legacy:
            break
        }
    }

    // MARK: - Основной цикл

    func tick() {
        var cfg = Config.load()
        guard let bat = Battery.read() else {
            let message = "не читается AppleSmartBattery"
            if lastError != message { log("Ошибка: \(message)") }
            lastError = message
            return
        }

        updateOneShot(cfg: &cfg, battery: bat)
        applyEnergyModeRequest(cfg: &cfg)
        refreshEnergyMode(battery: bat)

        // Инициализация фазы при первом тике и при входе в авто-режим.
        if lastMode == nil || lastMode != cfg.mode {
            phaseCharging = bat.percentage <= cfg.low
        }
        lastMode = cfg.mode

        let allowed = decide(cfg: cfg, battery: bat)
        let state = controller.api == .macOSLimit
            ? applySystemLimit(allowed: allowed, cfg: cfg, battery: bat)
            : apply(allowed: allowed, battery: bat)
        applyLED(cfg: cfg, requested: state.requested, battery: bat)
        recordHistory(bat)
        writeStatus(cfg: cfg, bat: bat, allowed: allowed, state: state)
        rotateLogIfNeeded()
    }

    /// Журнал пополняется только событиями, так что размер смотрим редко.
    /// Строка о самой ротации ложится уже в обрезанный файл — иначе о ней
    /// никто бы не узнал.
    private func rotateLogIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastLogRotateCheck) >= 300 else { return }
        lastLogRotateCheck = now
        guard let was = LogFile.rotateIfNeeded() else { return }
        log("Журнал перерос порог (\(was / 1024) КБ) и обрезан, "
            + "прошлое поколение — \(LogFile.archivePath)")
    }

    /// Разовая зарядка — это состояние в конфиге, а не одноразовое событие.
    ///
    /// Раньше демон «съедал» `chargeNow` на первом же тике и дальше жил своим
    /// флагом, который гасила только смена режима. Из-за этого «Не заряжать»,
    /// нажатое в режиме `hold` (то есть без смены режима), ничего не отменяло —
    /// зарядка спокойно шла до верхнего порога. Теперь флаг живёт в конфиге,
    /// любая команда, снявшая его, отменяет разовую зарядку, а гасит флаг
    /// демон — сам, по завершении.
    private func updateOneShot(cfg: inout Config, battery bat: BatteryInfo) {
        let requested = cfg.chargeNow
        var want = requested
        var note: String?

        if want, let last = lastMode, last != cfg.mode {
            want = false
            note = "Смена режима отменила разовую зарядку"
        }
        if want && bat.percentage >= cfg.high {
            want = false
            note = oneShot ? "Разовая зарядка завершена на \(bat.percentage)%"
                           : "Заряжать до \(cfg.high)% нечего: уже \(bat.percentage)%"
        }
        if !requested && oneShot {
            note = "Разовая зарядка отменена"
        }
        if want && !oneShot {
            note = "Получена команда: зарядить до \(cfg.high)%"
        }
        if let note, note != lastOneShotNote { log(note) }
        lastOneShotNote = note
        oneShot = want

        guard cfg.chargeNow != want else { return }
        cfg.chargeNow = want
        try? cfg.save()
        // Мы под root: без этого перезаписанный конфиг остался бы
        // с группой wheel, и приложение больше не смогло бы его менять.
        restoreConfigOwnership()
    }

    /// Выполняет просьбу сменить режим энергии и гасит её.
    ///
    /// Режим не наш: его меняют и в Настройках, и в Пункте управления, и
    /// удерживать его своим значением мы не вправе — иначе отняли бы у
    /// пользователя системный переключатель. Поэтому поле в конфиге живёт
    /// ровно один тик: применили — стёрли.
    private func applyEnergyModeRequest(cfg: inout Config) {
        guard let requested = cfg.energyModeRequest else { return }
        do {
            try EnergyModes.apply(requested)
            log("Режим энергии: \(requested.humanReadable)")
            lastError = nil
        } catch {
            let message = "\(error)"
            if lastError != message { log("Не удалось сменить режим энергии: \(message)") }
            lastError = message
        }
        cfg.energyModeRequest = nil
        try? cfg.save()
        restoreConfigOwnership()
        // Своё же изменение показываем сразу, не дожидаясь очередного опроса.
        lastEnergyModeRead = .distantPast
    }

    private func refreshEnergyMode(battery bat: BatteryInfo) {
        let now = Date()
        guard now.timeIntervalSince(lastEnergyModeRead) >= Daemon.energyModeInterval else { return }
        lastEnergyModeRead = now
        energyMode = EnergyModes.current(plugged: bat.isPluggedIn)
    }

    /// Единственное место, где решается, можно ли заряжать.
    private func decide(cfg: Config, battery bat: BatteryInfo) -> Bool {
        if oneShot { return true }

        switch cfg.mode {
        case .off:
            return true
        case .hold:
            return false
        case .auto:
            if bat.percentage <= cfg.low {
                phaseCharging = true
            } else if bat.percentage >= cfg.high {
                phaseCharging = false
            }
            return phaseCharging
        }
    }

    /// Что мы попросили у контроллера и что он на самом деле делает.
    struct ChargeState {
        let requested: Bool   // нужна ли блокировка по нашему решению
        let effective: Bool   // держим ли зарядку на самом деле
        let settling: Bool    // команда отправлена, но ещё не применена
    }

    /// Приводит SMC к нужному состоянию и возвращает, что происходит на самом деле.
    ///
    /// Записанный ключ — это команда, а не факт: контроллер заряда перечитывает
    /// его на своей периодической переоценке (на M4 это ~45–50 с), поэтому между
    /// записью и остановкой или стартом зарядки проходит до минуты. Раньше здесь
    /// возвращалось желаемое значение, и статус уверенно писал «заблокировано»,
    /// пока батарея брала 4 А. Факт берём из `NotChargingReason`: бит 55 —
    /// зарядку держим мы.
    ///
    /// Ключ сверяем каждый тик, а не только при смене решения: после сна он
    /// может сброситься сам.
    private func apply(allowed: Bool, battery bat: BatteryInfo) -> ChargeState {
        let shouldInhibit = !allowed
        if requestedInhibit != shouldInhibit {
            requestedInhibit = shouldInhibit
            requestChangedAt = Date()
        }
        guard controller.api != .unknown else {
            return ChargeState(requested: false, effective: false, settling: false)
        }
        do {
            if try controller.isInhibitRequested() != shouldInhibit {
                try controller.setChargingAllowed(allowed)
                log(allowed ? "Зарядка разрешена — контроллер применит в течение ~минуты"
                            : "Зарядка заблокирована — контроллер применит в течение ~минуты")
            }
            lastError = nil
        } catch {
            // Одна и та же ошибка на каждом тике залила бы лог сотней тысяч
            // одинаковых строк за сутки — пишем только смену состояния.
            let message = "\(error)"
            if lastError != message { log("Ошибка SMC: \(message)") }
            lastError = message
            // И не выдаём желаемое за действительное: запись не прошла, значит
            // зарядку держит не наш ключ. Без адаптера считаем, что не держим:
            // там `NotChargingReason` залипает на последнем значении.
            return ChargeState(requested: shouldInhibit,
                               effective: bat.isPluggedIn ? bat.ourInhibitActive : false,
                               settling: false)
        }
        // Без адаптера блокировать нечего, а `NotChargingReason` там залипает
        // на последнем значении — сверять его на батарее бессмысленно.
        let effective = bat.isPluggedIn ? bat.ourInhibitActive : shouldInhibit
        // Ждём применения только ограниченное время: расхождение может и не
        // сойтись (например, батарея полна и контроллер называет своей причиной
        // именно это), а вечный значок «применяется» хуже честного факта.
        let settling = effective != shouldInhibit
            && Date().timeIntervalSince(requestChangedAt) < Daemon.settleWindow
        return ChargeState(requested: shouldInhibit, effective: effective, settling: settling)
    }

    /// То же, что `apply`, но рычаг — лимит зарядки macOS, а не запрет в SMC.
    ///
    /// Лимит — это потолок, а не выключатель, поэтому решение переводится так:
    /// можно заряжать — потолок на верхнем пороге; нельзя — потолок на текущем
    /// заряде (`holdCeiling`). Ниже текущего не ставим: у политики powerd
    /// `drain: true`, и на новой сессии зарядки ноутбук стал бы разряжать
    /// батарею до потолка прямо от сети.
    ///
    /// В режиме «выключено» отпускаем управление: возвращаем лимит, который
    /// стоял до нас, и дальше в Настройки не вмешиваемся.
    private func applySystemLimit(allowed: Bool, cfg: Config, battery bat: BatteryInfo) -> ChargeState {
        guard let limit = controller.systemLimit else {
            return ChargeState(requested: false, effective: false, settling: false)
        }
        if cfg.mode == .off && !oneShot {
            releaseSystemLimit(limit)
            return ChargeState(requested: false, effective: false, settling: false)
        }

        let shouldInhibit = !allowed
        let target: Int
        if allowed {
            holdCeiling = nil
            target = cfg.high
        } else {
            let ceiling = min(holdCeiling ?? bat.percentage, bat.percentage)
            holdCeiling = ceiling
            target = max(ceiling, SystemChargeLimit.minimum)
        }

        do {
            try enforceSystemLimit(limit, target: target, allowed: allowed)
            lastError = nil
        } catch {
            let message = "\(error)"
            if lastError != message { log("Ошибка лимита macOS: \(message)") }
            lastError = message
        }

        // Факт — по `NotChargingReason`: бит 24 означает, что заряд держит
        // лимит macOS, то есть теперь мы. На батарее сверять нечего.
        let mismatch: Bool
        if !bat.isPluggedIn {
            mismatch = false
        } else if shouldInhibit {
            mismatch = bat.isCharging
        } else {
            mismatch = bat.systemLimitActive && bat.percentage < target
        }

        let now = Date()
        if mismatch {
            let since = mismatchSince ?? now
            mismatchSince = since
            if !nudgedThisMismatch && now.timeIntervalSince(since) >= Daemon.nudgeDelay {
                nudgedThisMismatch = true
                do {
                    try controller.nudgeCharger()
                    log("Контроллер не подхватил лимит \(target)% за \(Int(now.timeIntervalSince(since))) с — "
                        + "переподключил адаптер ключом CHIE")
                } catch {
                    log("Не удалось переподключить адаптер: \(error)")
                }
            }
        } else {
            mismatchSince = nil
            nudgedThisMismatch = false
        }
        let sinceWrite = now.timeIntervalSince(limitWrittenAt)

        return ChargeState(requested: shouldInhibit,
                           effective: shouldInhibit && !mismatch,
                           settling: mismatch && sinceWrite < Daemon.settleWindow)
    }

    /// Пишет лимит, если он отличается от нужного, и раз в несколько секунд
    /// сверяется с агентом: лимит могли поменять в Настройках или снять
    /// «Зарядить до конца» в меню батареи.
    private func enforceSystemLimit(_ limit: SystemChargeLimit, target: Int, allowed: Bool) throws {
        let now = Date()
        var drift: String?
        if appliedLimit == target {
            guard now.timeIntervalSince(lastLimitCheck) >= Daemon.limitCheckInterval else { return }
            lastLimitCheck = now
            if limit.isTemporarilyDisabled {
                drift = "лимит временно сняли из меню батареи"
            } else if let agent = limit.agentLimit(), agent != target {
                drift = "лимит поменяли в обход BatLimit (\(agent)%)"
                // Ползунок в Настройках двигал пользователь — это его выбор,
                // его и вернём, когда отпустим управление.
                if (80...100).contains(agent) { SystemChargeLimitBackup.save(agent) }
            }
            guard drift != nil else { return }
        }

        if SystemChargeLimitBackup.load() == nil {
            let original = limit.agentLimit() ?? 100
            SystemChargeLimitBackup.save(original)
            log("Беру под контроль лимит macOS, до BatLimit стоял \(original)%")
        }
        try limit.setLimit(target)

        if let drift {
            log("Лимит macOS: \(target)% — \(drift)")
        } else if lastLimitAllowed != allowed {
            // Потолок удержания ползёт вниз вместе с зарядом на батарее —
            // это не событие, в журнал пишем только смену решения.
            log(allowed ? "Лимит macOS: \(target)% — зарядка разрешена"
                        : "Лимит macOS: \(target)% — зарядка остановлена на текущем заряде")
        }
        lastLimitAllowed = allowed
        appliedLimit = target
        limitWrittenAt = now
        lastLimitCheck = now
        // Новая запись — новый шанс контроллеру справиться самому.
        mismatchSince = nil
        nudgedThisMismatch = false
    }

    /// Возвращает лимит, который стоял до BatLimit. Без резервной копии — нечего
    /// возвращать: управление уже отпущено или ни разу не бралось.
    private func releaseSystemLimit(_ limit: SystemChargeLimit) {
        holdCeiling = nil
        appliedLimit = nil
        lastLimitAllowed = nil
        guard let original = SystemChargeLimitBackup.load() else { return }
        do {
            try limit.setLimit(original)
            SystemChargeLimitBackup.remove()
            log("Лимит macOS возвращён: \(original)%")
            lastError = nil
        } catch {
            let message = "\(error)"
            if lastError != message { log("Не удалось вернуть лимит macOS: \(message)") }
            lastError = message
        }
    }

    /// Зелёный светодиод MagSafe = «питание есть, батарею намеренно не заряжаем».
    ///
    /// Смотрим на наше решение (`requested`), а не на факт из
    /// `NotChargingReason`. Бит 55 — живое показание контроллера: на
    /// переподключении адаптера и на каждой его переоценке он скачет по
    /// несколько раз за секунду, и светодиод скакал вместе с ним, каждый раз
    /// записывая SMC. За одно утро в логе набегало под 240 переключений.
    /// Смысл зелёного — «BatLimit намеренно удерживает зарядку», а это именно
    /// решение, и оно меняется только со сменой режима.
    ///
    /// Выдержка — страховка на остальное: дребезг `ExternalConnected` при
    /// неплотном разъёме иначе дал бы ту же картину.
    private func applyLED(cfg: Config, requested: Bool, battery bat: BatteryInfo) {
        guard controller.hasMagSafeLED else { return }
        let desired: ChargingController.LED =
            (cfg.magsafeLED && requested && bat.isPluggedIn) ? .green : .auto

        if desired != pendingLED {
            pendingLED = desired
            pendingLEDSince = Date()
        }
        // Первое решение после запуска принимаем сразу: ждать пять секунд,
        // чтобы отдать светодиод системе, незачем.
        guard lastLED == nil
                || Date().timeIntervalSince(pendingLEDSince) >= Daemon.ledDebounce else { return }

        if desired == .green {
            // Систему приходится переубеждать: она возвращает свой цвет,
            // поэтому сверяем фактическое значение на каждом тике.
            if controller.currentLED() != .green {
                try? controller.setLED(.green)
            }
            if lastLED != .green { log("Индикатор MagSafe: зелёный") }
        } else if lastLED != .auto {
            // Обратно отдаём управление системе один раз, иначе будем
            // бесконечно спорить с ней о цвете.
            try? controller.setLED(.auto)
            log("Индикатор MagSafe: возвращён системе")
        }
        lastLED = desired
    }

    /// Точка в истории заряда — раз в минуту, для графика в панели мониторинга.
    private func recordHistory(_ bat: BatteryInfo) {
        let now = Date()
        guard now.timeIntervalSince(lastHistoryWrite) >= 60 else { return }
        lastHistoryWrite = now
        History.append(HistoryPoint(t: now.timeIntervalSince1970,
                                    p: bat.percentage,
                                    c: bat.isCharging,
                                    a: bat.isPluggedIn))
        if now.timeIntervalSince(lastTrim) > 3600 {
            lastTrim = now
            History.trim()
        }
    }

    private func writeStatus(cfg: Config, bat: BatteryInfo, allowed: Bool, state: ChargeState) {
        let phase = describePhase(cfg: cfg, bat: bat, allowed: allowed, state: state)
        let status = Status(percentage: bat.percentage,
                            isCharging: bat.isCharging,
                            isPluggedIn: bat.isPluggedIn,
                            inhibited: state.effective,
                            settling: state.settling,
                            systemLimitActive: systemLimitIsForeign(bat),
                            mode: cfg.mode,
                            low: cfg.low,
                            high: cfg.high,
                            chargeNow: oneShot,
                            phase: phase.russian(plugged: bat.isPluggedIn,
                                                 low: cfg.low, high: cfg.high),
                            phaseKind: phase,
                            api: controller.api.rawValue,
                            minutesRemaining: bat.isCharging ? bat.minutesToFull : bat.minutesToEmpty,
                            cycleCount: bat.cycleCount,
                            energyMode: energyMode,
                            highPowerAvailable: highPowerAvailable,
                            magsafeLEDAvailable: controller.hasMagSafeLED,
                            error: lastError,
                            updatedAt: Date())

        // Пишем только при изменении сути либо раз в 15 секунд — чтобы статус
        // оставался «свежим» для клиентов, но не молотить диск вхолостую.
        let fingerprint = "\(status.percentage)|\(status.isCharging)|\(status.isPluggedIn)|"
            + "\(status.inhibited)|\(status.settling ?? false)|\(status.mode)|"
            + "\(status.low)|\(status.high)|\(status.chargeNow)|"
            + "\(status.phase)|\(status.energyMode?.rawValue ?? "")|\(status.error ?? "")"
        let stale = Date().timeIntervalSince(lastStatusWrite) > 15
        guard fingerprint != lastWrittenStatus || stale else { return }

        do {
            try status.save()
            lastWrittenStatus = fingerprint
            lastStatusWrite = Date()
        } catch {
            log("Не удалось записать статус: \(error)")
        }
    }

    private func describePhase(cfg: Config, bat: BatteryInfo, allowed: Bool,
                               state: ChargeState) -> PhaseKind {
        if controller.api == .unknown { return .noController }

        // Контроллер применяет команду не сразу — не делаем вид, что уже готово.
        if state.settling {
            return allowed ? .releasing : .inhibiting
        }
        // Системный лимит macOS — второй, независимый замок: он держит зарядку
        // своим битом 24 и нашим ключом не открывается.
        if allowed && bat.isPluggedIn && systemLimitIsForeign(bat) && bat.percentage < cfg.high {
            return .systemLimitHolds
        }
        // Окно ожидания вышло, а запрет так и не подействовал — это аномалия,
        // и молчать о ней нельзя: пользователь видит, что батарея заряжается.
        if state.requested && !state.effective && bat.isCharging {
            return .inhibitIgnored
        }
        if oneShot { return .oneShot }

        switch cfg.mode {
        case .off:  return .notManaging
        case .hold: return .blocked
        case .auto: return allowed ? .chargingToHigh : .waitingForLow
        }
    }

    /// Бит 24 — зарядку держит лимит macOS. Чужой это замок или наш, зависит
    /// от рычага: при `.macOSLimit` лимитом управляем мы сами.
    private func systemLimitIsForeign(_ bat: BatteryInfo) -> Bool {
        controller.api != .macOSLimit && bat.systemLimitActive
    }

    /// Конфиг принадлежит root:admin — его правят приложение и CLI без sudo.
    private func restoreConfigOwnership() {
        try? FileManager.default.setAttributes([
            .ownerAccountName: "root",
            .groupOwnerAccountName: "admin",
            .posixPermissions: 0o664,
        ], ofItemAtPath: Paths.config)
    }

    // MARK: - Завершение

    /// При остановке всегда снимаем блокировку: демон не должен оставить
    /// ноутбук с навсегда запрещённой зарядкой.
    func shutdown() {
        log("Останов: снимаю блокировку зарядки")
        switch controller.api {
        case .tahoe, .legacy:
            try? controller.setChargingAllowed(true)
        case .macOSLimit:
            _ = controller.resetAdapterIfDisabled()
            if let limit = controller.systemLimit { releaseSystemLimit(limit) }
        case .unknown:
            break
        }
        if controller.hasMagSafeLED {
            try? controller.setLED(.auto)
        }
        if var status = Status.load() {
            status.inhibited = false
            status.settling = false
            status.phaseKind = .daemonStopped
            status.phase = PhaseKind.daemonStopped.russian(plugged: status.isPluggedIn,
                                                           low: status.low, high: status.high)
            status.updatedAt = Date()
            try? status.save()
        }
    }
}

// MARK: - Точка входа

guard getuid() == 0 else {
    FileHandle.standardError.write("batlimitd должен работать от root\n".data(using: .utf8)!)
    exit(1)
}

let daemon: Daemon
do {
    daemon = try Daemon()
} catch {
    FileHandle.standardError.write("Не удалось инициализировать SMC: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// Сигналы обрабатываем через DispatchSource, а не через signal(): обработчик
// сигнала не может безопасно ходить в IOKit и файловую систему.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// Ссылку держим в глобальной переменной: иначе источники освободятся сразу
// после создания и сигналы перестанут обрабатываться.
let signalSources: [DispatchSourceSignal] = [SIGTERM, SIGINT].map { sig in
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    src.resume()
    return src
}

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: 1.0)
timer.setEventHandler { daemon.tick() }
timer.resume()

dispatchMain()
