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
    private var energyModes = EnergyModePair()
    private var lastEnergyModeRead = Date.distantPast
    private static let energyModeInterval: TimeInterval = 5
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
    /// Идёт ли калибровочная зарядка macOS — чтобы записать в журнал только
    /// вход в это состояние и выход из него, а не каждый тик.
    private var lastCalibrating = false
    /// То же для возврата заряда к порогу.
    private var lastDraining = false
    /// Когда в последний раз отодвигали повод для калибровки и сколько раз
    /// подряд. Перезапуск powerd — не та вещь, которую стоит повторять часто:
    /// если после трёх попыток он всё равно просит зарядку до 100 %, значит
    /// причина не в датах, и дальше мы только мешали бы системе.
    private var lastPostpone = Date.distantPast
    private var postponeAttempts = 0
    /// До этого момента адаптер не дёргаем: powerd только что перезапущен
    /// и лимит ему нужно отдать заново, на это уходит до минуты.
    private var quietUntil = Date.distantPast
    /// Умеет ли эта версия macOS то, чем мы отменяем калибровку. Спрашиваем
    /// редко: ответ меняется разве что с обновлением системы. Выставляется
    /// в `init`, когда уже известен рычаг.
    private var calibrationControlAvailable = false
    private var lastCalibrationCheck = Date()
    private static let calibrationCheckInterval: TimeInterval = 3600
    /// Калибровку позвал сам пользователь — значит отменять её не надо,
    /// даже если в настройках стоит «не давать калибровать».
    private var manualCalibration = false
    private var manualCalibrationSince: Date?
    /// Сколько ждём начала позванной калибровки: не началась — значит система
    /// её не захотела, и дальше настройка снова в силе.
    private static let manualCalibrationWait: TimeInterval = 600
    private static let postponeInterval: TimeInterval = 900
    private static let postponeAttemptLimit = 3
    /// Решение, при котором писали лимит в последний раз, — для журнала.
    private var lastLimitAllowed: Bool?
    private var lastLimitCheck = Date.distantPast
    /// Сколько расхождение должно продержаться, прежде чем толкать контроллер.
    /// Сам он подхватывает новый лимит за ~10 с, а `IsCharging` на подключении
    /// адаптера на мгновение взводится и при удержанном заряде.
    private static let nudgeDelay: TimeInterval = 20
    /// Как часто сверяться с агентом: лимит могут поменять в Настройках.
    private static let limitCheckInterval: TimeInterval = 5

    // MARK: Лимит прошивки (api == .firmwareLimit)

    /// Коридор, записанный в прошивку в последний раз. `holdCeiling`,
    /// `lastLimitAllowed` и `lastLimitCheck` — общие с лимитом macOS.
    private var appliedFirmwareLimit: FirmwareLimit?
    /// Лимит снят нами и с тех пор не ставился — снимать снова незачем.
    private var firmwareReleased = false
    /// После отказа SMC не повторяем запись раньше этого момента.
    private var firmwareRetryAt = Date.distantPast
    private static let firmwareRetryInterval: TimeInterval = 30

    init() throws {
        controller = try ChargingController()
        calibrationControlAvailable = calibrationControlSupported
        log("Запуск. Управление зарядкой: \(controller.api.rawValue)")
        switch controller.api {
        case .unknown:
            log("ВНИМАНИЕ: ни SMC-ключей, ни лимита прошивки, ни лимита macOS нет, управлять зарядкой не смогу")
        case .macOSLimit:
            let agent = controller.systemLimit?.agentLimit().map { "\($0)%" } ?? "не отвечает"
            log("Лимит macOS сейчас: \(agent)"
                + (SystemChargeLimitBackup.load().map { ", до BatLimit стоял \($0)%" } ?? ""))
            if controller.resetAdapterIfDisabled() {
                log("Адаптер был отключён ключом CHIE — включён обратно")
            }
        case .firmwareLimit:
            // Лимит прошивки мог пережить прошлый запуск службы: скажем, какой.
            let current = controller.firmwareLimit()
                .map { "\($0.lower)–\($0.upper)%" } ?? "выключен"
            log("Лимит прошивки сейчас: \(current)")
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
        applyCalibrationRequest(cfg: &cfg)
        applyEnergyModeRequest(cfg: &cfg)
        refreshEnergyMode()

        // Инициализация фазы при первом тике и при входе в авто-режим.
        if lastMode == nil || lastMode != cfg.mode {
            phaseCharging = bat.percentage <= cfg.low
        }
        lastMode = cfg.mode

        let allowed = decide(cfg: cfg, battery: bat)
        let state: ChargeState
        switch controller.api {
        case .macOSLimit:    state = applySystemLimit(allowed: allowed, cfg: cfg, battery: bat)
        case .firmwareLimit: state = applyFirmwareLimit(allowed: allowed, cfg: cfg, battery: bat)
        case .tahoe, .legacy, .unknown: state = apply(allowed: allowed, battery: bat)
        }
        // Во время калибровки зелёный «удерживаю» неуместен — батарея реально
        // заряжается, пусть светодиод показывает это по-системному.
        applyLED(cfg: cfg, requested: state.requested && !state.calibrating, battery: bat)
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

    /// Выполняет разовую просьбу про калибровку и гасит её.
    ///
    /// Просьба начать калибровку сильнее настройки «не давать калибровать»:
    /// раз пользователь сам её позвал, мешать ей мы не будем, пока она не
    /// закончится.
    private func applyCalibrationRequest(cfg: inout Config) {
        guard let request = cfg.calibrationRequest else { return }
        cfg.calibrationRequest = nil
        try? cfg.save()
        restoreConfigOwnership()

        // И «остановить», и «откалибровать» перезапускают powerd.
        guard calibrationControlAvailable else {
            log("Просьба про калибровку не выполнена: на этой системе BatLimit калибровкой не управляет")
            return
        }

        do {
            switch request {
            case .stop:
                manualCalibration = false
                guard SystemCalibration.chargingToFull else {
                    log("Остановить калибровку не о чем: система её сейчас не ведёт")
                    return
                }
                try CalibrationControl.postpone()
                log("Калибровка остановлена по просьбе — отодвинул повод и перезапустил powerd")
                // Флаг гаснет через несколько секунд; до тех пор автоматика
                // не должна перезапускать powerd второй раз подряд.
                lastPostpone = Date()
                calibrationRestarted()
            case .start:
                try CalibrationControl.requestNow()
                manualCalibration = true
                manualCalibrationSince = Date()
                log("Просьба откалибровать батарею: пометил данные датчика устаревшими "
                    + "и перезапустил powerd — зарядка пойдёт до 100 %")
                calibrationRestarted()
            }
            lastError = nil
        } catch {
            let message = "\(error)"
            log("Не удалось выполнить просьбу про калибровку: \(message)")
            lastError = message
        }
    }

    /// Общее последствие перезапуска powerd: лимит ему нужно отдать заново,
    /// и до тех пор расхождение — не повод дёргать адаптер.
    private func calibrationRestarted() {
        appliedLimit = nil
        appliedFirmwareLimit = nil
        holdCeiling = nil
        let now = Date()
        limitWrittenAt = now
        quietUntil = now.addingTimeInterval(Daemon.settleWindow)
        mismatchSince = nil
        nudgedThisMismatch = false
    }

    /// Выполняет просьбу сменить режим энергии и гасит её.
    ///
    /// Режим не наш: его меняют и в Настройках, и в Пункте управления, и
    /// удерживать его своим значением мы не вправе — иначе отняли бы у
    /// пользователя системный переключатель. Поэтому поле в конфиге живёт
    /// ровно один тик: применили — стёрли.
    private func applyEnergyModeRequest(cfg: inout Config) {
        guard let requests = cfg.energyModeRequests else { return }
        // У батареи и у сети свои режимы, как в Настройках: просьба может
        // касаться одного источника, другого или обоих.
        for source in PowerSourceKey.allCases {
            guard let requested = requests[source] else { continue }
            do {
                try EnergyModes.apply(requested, source: source)
                log("Режим энергии \(source.humanReadable): \(requested.humanReadable)")
                lastError = nil
            } catch {
                let message = "\(error)"
                if lastError != message {
                    log("Не удалось сменить режим энергии \(source.humanReadable): \(message)")
                }
                lastError = message
            }
        }
        cfg.energyModeRequests = nil
        try? cfg.save()
        restoreConfigOwnership()
        // Своё же изменение показываем сразу, не дожидаясь очередного опроса.
        lastEnergyModeRead = .distantPast
    }

    private func refreshEnergyMode() {
        let now = Date()
        guard now.timeIntervalSince(lastEnergyModeRead) >= Daemon.energyModeInterval else { return }
        lastEnergyModeRead = now
        energyModes = EnergyModes.current()
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
        let requested: Bool     // нужна ли блокировка по нашему решению
        let effective: Bool     // держим ли зарядку на самом деле
        let settling: Bool      // команда отправлена, но ещё не применена
        var calibrating = false // macOS ведёт калибровочную зарядку до 100 %
        var draining = false    // заряд выше порога, macOS сводит его к порогу
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

        // macOS раз в несколько дней сама заряжает батарею до 100 % для
        // калибровки датчика заряда и на это время отключает лимит. Пока это
        // идёт, лимит ничего не держит: переписывать его бессмысленно (мы лишь
        // затирали бы правку пользователя в Настройках), а переподключать
        // адаптер — тем более (powerd тут же продолжит зарядку, а мы лишь мигали
        // бы адаптером по кругу). Отступаем: заряд ведёт система, вернёмся к
        // удержанию, когда калибровка закончится.
        let calibrating = updateCalibration(cfg: cfg)

        let shouldInhibit = !allowed
        // Заряд выше порога — по умолчанию просто не подзаряжаем и ждём, пока
        // он сойдёт вниз сам. Если же попросили возвращать его к порогу,
        // лимит ставим ниже текущего заряда: это macOS понимает как просьбу
        // свести заряд к нему и питает ноутбук от батареи прямо от адаптера.
        let draining = shouldInhibit && cfg.dischargeToHigh && !calibrating
            && bat.isPluggedIn && bat.percentage > cfg.high
        if draining != lastDraining {
            if draining {
                log("Заряд \(bat.percentage)% выше порога \(cfg.high)% — прошу macOS вернуть его к порогу")
            } else if lastDraining {
                log("Заряд вернулся к порогу \(cfg.high)%")
            }
            lastDraining = draining
        }
        let target: Int
        if allowed || draining {
            holdCeiling = nil
            target = cfg.high
        } else {
            let ceiling = min(holdCeiling ?? bat.percentage, bat.percentage)
            holdCeiling = ceiling
            target = max(ceiling, SystemChargeLimit.minimum)
        }

        if !calibrating {
            do {
                try enforceSystemLimit(limit, target: target, allowed: allowed)
                lastError = nil
            } catch {
                let message = "\(error)"
                if lastError != message { log("Ошибка лимита macOS: \(message)") }
                lastError = message
            }
        }

        // Факт — по `NotChargingReason`: бит 24 означает, что заряд держит
        // лимит macOS, то есть теперь мы. На батарее сверять нечего.
        let mismatch: Bool
        if !bat.isPluggedIn || calibrating {
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
            if !nudgedThisMismatch && now >= quietUntil
                && now.timeIntervalSince(since) >= Daemon.nudgeDelay {
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
                           // Во время калибровки заряд ведёт система, а не мы:
                           // не выдаём удержание за действительное.
                           effective: shouldInhibit && !mismatch && !calibrating,
                           settling: mismatch && sinceWrite < Daemon.settleWindow,
                           calibrating: calibrating && shouldInhibit,
                           draining: draining)
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

    /// Можно ли здесь отменять и звать калибровку.
    ///
    /// Отмена перезапускает powerd, а проверена она только на macOS 27 —
    /// с лимитом macOS. Лимит прошивки живёт на Sequoia, где это не проверено,
    /// и перезапускать системную службу вслепую мы не станем: калибровке
    /// там BatLimit не мешает, а на время её просто отступает.
    private var calibrationControlSupported: Bool {
        controller.api != .firmwareLimit && CalibrationControl.isAvailable
    }

    /// Следит за калибровочной зарядкой macOS и возвращает, идёт ли она.
    ///
    /// Общее для рычагов-потолков (лимит macOS и лимит прошивки): пишет в журнал
    /// вход и выход, по окончании начинает удержание заново и, если
    /// пользователь не хочет калибровку, отодвигает её повод.
    private func updateCalibration(cfg: Config) -> Bool {
        if Date().timeIntervalSince(lastCalibrationCheck) >= Daemon.calibrationCheckInterval {
            lastCalibrationCheck = Date()
            calibrationControlAvailable = calibrationControlSupported
        }
        let calibrating = SystemCalibration.chargingToFull
        if calibrating != lastCalibrating {
            log(calibrating
                ? "macOS начала калибровочную зарядку до 100 % — отступаю, лимит сейчас держит система"
                : "Калибровочная зарядка macOS завершена — возвращаюсь к удержанию заряда")
            // Калибровка подняла заряд выше того потолка, на котором мы его
            // держали. Держаться за старое число теперь нельзя: лимит ниже
            // текущего заряда macOS понимает как просьбу разрядить батарею,
            // а гнать заряд вниз мы не собирались — начинаем удержание заново,
            // от того заряда, который есть.
            if !calibrating {
                postponeAttempts = 0
                holdCeiling = nil
                manualCalibration = false
                manualCalibrationSince = nil
            }
            lastCalibrating = calibrating
        }
        // Позванная вручную калибровка успела не начаться — ждём её недолго,
        // иначе настройка «не давать калибровать» осталась бы выключенной.
        if let since = manualCalibrationSince, !calibrating,
           Date().timeIntervalSince(since) > Daemon.manualCalibrationWait {
            manualCalibration = false
            manualCalibrationSince = nil
            log("Позванная калибровка так и не началась — возвращаюсь к обычному поведению")
        }
        // Если пользователь не хочет калибровку — отодвигаем её повод, пока
        // заряд не успел уйти вверх.
        if calibrating && cfg.preventCalibration && !manualCalibration
            && calibrationControlAvailable { postponeCalibration() }
        return calibrating
    }

    // MARK: Лимит прошивки (api == .firmwareLimit)

    /// То же, что `applySystemLimit`, но потолок держит сама прошивка SMC
    /// (`bfF0`/`bfD0`/`bfE0`), без powerd и PowerUIAgent.
    ///
    /// Решение переводится в коридор так же: можно заряжать — верхний порог на
    /// `high`; нельзя — на текущем заряде (`holdCeiling`, только опускается).
    /// Коридор держит прошивка, а не мы, поэтому он работает и во сне: «можно
    /// заряжать» не значит «заряжать до 100 %, пока служба спит».
    ///
    /// Факт — по биту 55 в `NotChargingReason`, как у `CHTE`; контроллер
    /// применяет новый коридор не сразу, замерено около минуты.
    private func applyFirmwareLimit(allowed: Bool, cfg: Config, battery bat: BatteryInfo) -> ChargeState {
        if cfg.mode == .off && !oneShot {
            releaseFirmwareLimit()
            return ChargeState(requested: false, effective: false, settling: false)
        }
        // Снимает ли powerd на калибровку лимит прошивки, на Sequoia не
        // проверено. Пока флаг поднят, коридор не переписываем — не спорим
        // с системой; а «macOS калибрует» показываем, только если батарея
        // и правда заряжается.
        let calibrationRequested = updateCalibration(cfg: cfg)
        let calibrating = calibrationRequested && bat.isPluggedIn && bat.isCharging

        let shouldInhibit = !allowed
        if requestedInhibit != shouldInhibit {
            requestedInhibit = shouldInhibit
            requestChangedAt = Date()
        }

        let target: FirmwareLimit
        if allowed {
            holdCeiling = nil
            target = .holding(at: cfg.high)
        } else {
            let ceiling = min(holdCeiling ?? bat.percentage, bat.percentage)
            holdCeiling = ceiling
            target = .holding(at: ceiling)
        }
        if !calibrationRequested { enforceFirmwareLimit(target, allowed: allowed) }

        // Без адаптера `NotChargingReason` залипает на последнем значении.
        let effective = bat.isPluggedIn ? bat.ourInhibitActive : shouldInhibit
        let settling = effective != shouldInhibit
            && Date().timeIntervalSince(requestChangedAt) < Daemon.settleWindow
        return ChargeState(requested: shouldInhibit,
                           effective: effective && !calibrating,
                           settling: settling && !calibrating,
                           calibrating: calibrating && shouldInhibit)
    }

    /// Пишет коридор, если он отличается от нужного, и раз в несколько секунд
    /// сверяет его с прошивкой: после сна или чужой записи он мог смениться.
    private func enforceFirmwareLimit(_ target: FirmwareLimit, allowed: Bool) {
        let now = Date()
        var drift: String?
        if appliedFirmwareLimit == target {
            guard now.timeIntervalSince(lastLimitCheck) >= Daemon.limitCheckInterval else { return }
            lastLimitCheck = now
            let actual = controller.firmwareLimit()
            guard actual != target else { return }
            drift = actual.map { "коридор сменили в обход BatLimit (\($0.lower)–\($0.upper)%)" }
                ?? "лимит сняли в обход BatLimit"
        } else if now < firmwareRetryAt {
            return
        }

        do {
            try controller.setFirmwareLimit(target)
            lastError = nil
            // Новый коридор — новая команда контроллеру, и применит он её не
            // сразу: с этого момента и считаем окно «применяется…». Иначе после
            // «выключено → авто» решение «держать» совпало бы с прежним, отсчёт
            // не начался бы, и минута законной задержки выглядела бы аномалией.
            requestChangedAt = now
        } catch {
            // Отказ на каждом тике — это запись в SMC раз в секунду и строка
            // в журнале раз в секунду. Повторяем реже и пишем только новое.
            firmwareRetryAt = now.addingTimeInterval(Daemon.firmwareRetryInterval)
            appliedFirmwareLimit = nil
            let message = "\(error)"
            if lastError != message { log("Ошибка лимита прошивки: \(message)") }
            lastError = message
            return
        }

        let range = "\(target.lower)–\(target.upper)%"
        if let drift {
            log("Лимит прошивки: \(range) — \(drift)")
        } else if lastLimitAllowed != allowed {
            // Потолок удержания ползёт вниз вместе с зарядом на батарее —
            // это не событие, в журнал пишем только смену решения.
            log(allowed ? "Лимит прошивки: \(range) — зарядка разрешена до верхнего порога"
                        : "Лимит прошивки: \(range) — зарядка остановлена на текущем заряде, "
                          + "контроллер применит в течение ~минуты")
        }
        lastLimitAllowed = allowed
        appliedFirmwareLimit = target
        firmwareReleased = false
        lastLimitCheck = now
    }

    /// Снимает лимит прошивки: «заряжать как обычно» — это обычная зарядка
    /// до 100 %, без нашего коридора.
    private func releaseFirmwareLimit() {
        holdCeiling = nil
        lastLimitAllowed = nil
        appliedFirmwareLimit = nil
        requestedInhibit = nil
        guard !firmwareReleased else { return }
        // Снимать нечего — например, служба только запустилась в режиме «выключено».
        guard controller.firmwareLimit() != nil else {
            firmwareReleased = true
            return
        }
        do {
            try controller.clearFirmwareLimit()
            firmwareReleased = true
            log("Лимит прошивки снят — зарядка как обычно")
            lastError = nil
        } catch {
            let message = "\(error)"
            if lastError != message { log("Не удалось снять лимит прошивки: \(message)") }
            lastError = message
        }
    }

    /// Отменяет калибровочную зарядку macOS: сдвигает даты, по которым powerd
    /// решил, что пора заряжать до 100 %, и перезапускает его (подробности —
    /// в `CalibrationControl`).
    private func postponeCalibration() {
        let now = Date()
        guard now.timeIntervalSince(lastPostpone) >= Daemon.postponeInterval else { return }
        guard postponeAttempts < Daemon.postponeAttemptLimit else { return }
        lastPostpone = now
        postponeAttempts += 1
        do {
            try CalibrationControl.postpone()
            log("macOS собралась калибровать батарею — отодвинул повод "
                + "и перезапустил powerd (попытка \(postponeAttempts))")
            lastError = nil
            // powerd поднялся с чистого листа: лимит ему нужно отдать заново,
            // а расхождение, пока он этого не сделал, — не повод дёргать
            // адаптер. Иначе каждая отменённая калибровка кончалась бы
            // переподключением питания на ровном месте.
            calibrationRestarted()
        } catch {
            let message = "\(error)"
            if lastError != message { log("Не удалось отменить калибровку: \(message)") }
            lastError = message
            if postponeAttempts >= Daemon.postponeAttemptLimit {
                log("Калибровку отменить не удалось — больше не пробую, "
                    + "заряд на это время ведёт система")
            }
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
                            energyModes: energyModes,
                            magsafeLEDAvailable: controller.hasMagSafeLED,
                            dischargeAvailable: controller.api == .macOSLimit,
                            calibrating: SystemCalibration.chargingToFull,
                            calibrationControl: calibrationControlAvailable,
                            error: lastError,
                            updatedAt: Date())

        // Пишем только при изменении сути либо раз в 15 секунд — чтобы статус
        // оставался «свежим» для клиентов, но не молотить диск вхолостую.
        let fingerprint = "\(status.percentage)|\(status.isCharging)|\(status.isPluggedIn)|"
            + "\(status.inhibited)|\(status.settling ?? false)|\(status.mode)|"
            + "\(status.low)|\(status.high)|\(status.chargeNow)|"
            + "\(status.phase)|\(status.energyModes?.battery?.rawValue ?? "")/\(status.energyModes?.ac?.rawValue ?? "")|\(status.error ?? "")"
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

        // macOS ведёт свою калибровочную зарядку до 100 % — лимит она сейчас
        // не применяет, и мы не мешаем. Честно называем, кто ведёт заряд.
        if state.calibrating {
            return .systemCalibrating
        }
        // Заряд сводится к порогу: это не «блокирую зарядку», а отдельное
        // состояние — ноутбук идёт от батареи, хотя адаптер подключён.
        if state.draining {
            return .dischargingToHigh
        }
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
        case .firmwareLimit:
            // Коридор держит прошивка и без нас — оставь его, и после удаления
            // службы батарея так и не зарядилась бы выше порога.
            try? controller.clearFirmwareLimit()
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
