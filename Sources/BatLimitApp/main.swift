import AppKit
import ServiceManagement
import BatLimitCore

// BatLimit — иконка в строке меню. Сама по себе привилегий не имеет: пишет
// config.json и читает status.json. Всё, что касается SMC, делает служба
// batlimitd, которую приложение устанавливает при первом запуске.

final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate, SettingsActions {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let menu = NSMenu()

    /// До этого момента молчание службы считаем нормальным. При входе в систему
    /// login item поднимается раньше LaunchDaemon — на этой машине разрыв
    /// доходил до 16 секунд, и всё это время в строке меню висел «не отвечает».
    private var graceUntil = Date().addingTimeInterval(45)

    private var titleItem: NSMenuItem!
    private var phaseItem: NSMenuItem!
    private var warningItem: NSMenuItem!
    /// Единственный след службы в меню: пока она не установлена или устарела,
    /// строка ведёт в настройки, где этим и занимаются.
    private var serviceItem: NSMenuItem!

    private var chargingItem: NSMenuItem!
    private var holdItem: NSMenuItem!
    private var chargeItem: NSMenuItem!
    private var autoItem: NSMenuItem!
    private var offItem: NSMenuItem!
    private var lowMenuItem: NSMenuItem!
    private var highMenuItem: NSMenuItem!

    private var energyItem: NSMenuItem!
    /// Пункты режима энергии — у батареи и у сети свои, как в Настройках.
    private var energyModeItems: [PowerSourceKey: [NSMenuItem]] = [:]

    private var monitorItem: NSMenuItem!
    private var settingsItem: NSMenuItem!

    /// Появляется, только когда фоновая проверка нашла новую версию.
    private var updateItem: NSMenuItem!

    private let monitorWindow = MonitorWindowController()
    private let settingsWindow = SettingsWindowController()
    private var updates: UpdateController!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    /// Чем помечена установленная служба: отпечатком её бинарника.
    /// Считается один раз: файл за время работы приложения не меняется,
    /// а SHA-256 по нему на каждом обновлении меню — это лишнее чтение диска.
    private lazy var daemonFingerprint: String = {
        resource("batlimitd").flatMap { HelperInstaller.fingerprint(ofFileAt: $0) } ?? version
    }()

    // MARK: - Жизненный цикл

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Доступностью пунктов управляем сами: при автоматическом включении
        // AppKit смотрит только на наличие target/action и возвращает всё
        // обратно, из-за чего `isEnabled = live` ниже был мёртвым кодом.
        menu.autoenablesItems = false
        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
        migrateLegacyLoginAgent()
        refresh()

        updates = UpdateController()
        updates.onPendingChange = { [weak self] in self?.updatePendingUpdateItem() }

        // Таймер добавляем в общие режимы: в `.default` он замирает, пока
        // открыто меню, — а именно там на него и смотрят. Из-за этого
        // раскрытое меню показывало состояние на момент открытия и не
        // оживало, даже когда служба уже отвечала.
        let refreshTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer

        // После сна служба обновляет статус в течение секунды — не пугаем
        // пользователя треугольником в это окно.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)

        // Вид значка меняют в окне настроек — оно и сообщает, когда перерисовать.
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesChanged),
            name: .appPreferencesChanged, object: nil)

        // Диалог показываем после того, как иконка появилась в строке меню:
        // иначе пользователь получает запрос пароля непонятно от чего.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.ensureHelperInstalled()
        }
    }

    @objc private func systemDidWake() {
        graceUntil = Date().addingTimeInterval(10)
        refresh()
    }

    @objc private func preferencesChanged() {
        refresh()
    }

    /// Открытое меню перерисовываем сразу, не дожидаясь очередного тика.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Установка службы

    private func resource(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: nil)
    }

    private func ensureHelperInstalled() {
        let state = HelperInstaller.state(bundledVersion: daemonFingerprint)
        if case .ready = state { return }

        // Проверяем машину до того, как просить пароль администратора: ставить
        // службу на Intel или на Mac без батареи бессмысленно.
        let check = SystemCheck.run()
        guard check.isSupported else {
            showError(L("alert.unsupported.title"), check.summary)
            return
        }

        switch state {
        case .ready:
            return

        case .notInstalled:
            let alert = NSAlert()
            alert.messageText = L("alert.install.title")
            alert.informativeText = L("alert.install.body")
            alert.addButton(withTitle: L("alert.install.ok"))
            alert.addButton(withTitle: L("alert.install.cancel"))
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performInstall()

        case .outdated:
            let alert = NSAlert()
            alert.messageText = L("alert.update.title")
            alert.informativeText = L("alert.update.body")
            alert.addButton(withTitle: L("alert.update.ok"))
            alert.addButton(withTitle: L("alert.update.cancel"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performInstall()
        }
    }

    private func performInstall() {
        guard let script = resource("install-helper.sh"), let daemon = resource("batlimitd") else {
            showError(L("alert.incomplete.title"), L("alert.incomplete.install"))
            return
        }
        do {
            try HelperInstaller.install(scriptPath: script, daemonPath: daemon,
                                        version: daemonFingerprint)
            // Демону нужно мгновение на первый тик и запись статуса.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        } catch HelperInstaller.InstallError.cancelled {
            return
        } catch {
            showError(L("alert.installFailed.title"), "\(error)")
        }
        refresh()
    }

    private func uninstallHelper() {
        let alert = NSAlert()
        alert.messageText = L("alert.uninstall.title")
        alert.informativeText = L("alert.uninstall.body")
        alert.addButton(withTitle: L("alert.uninstall.ok"))
        alert.addButton(withTitle: L("alert.uninstall.cancel"))
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let script = resource("uninstall-helper.sh") else {
            showError(L("alert.incomplete.title"), L("alert.incomplete.uninstall"))
            return
        }
        do {
            try HelperInstaller.uninstall(scriptPath: script)
        } catch HelperInstaller.InstallError.cancelled {
            return
        } catch {
            showError(L("alert.uninstallFailed.title"), "\(error)")
        }
        refresh()
    }

    private func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Автозапуск

    enum LoginState { case off, on, needsApproval }

    /// Автозапуск регистрируем через SMAppService: только так приложение
    /// появляется в «Настройки → Основные → Элементы входа». Самодельный
    /// LaunchAgent в ~/Library/LaunchAgents туда не попадает — из-за этого
    /// прежняя версия выглядела сломанной.
    private var loginState: LoginState {
        switch SMAppService.mainApp.status {
        case .enabled:          return .on
        case .requiresApproval: return .needsApproval
        default:                return .off
        }
    }

    private func toggleLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    promptLoginApproval()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError(L("alert.loginFailed.title"), error.localizedDescription)
        }
        settingsWindow.refresh()
    }

    private func promptLoginApproval() {
        let alert = NSAlert()
        alert.messageText = L("alert.loginApproval.title")
        alert.informativeText = L("alert.loginApproval.body")
        alert.addButton(withTitle: L("alert.loginApproval.ok"))
        alert.addButton(withTitle: L("alert.loginApproval.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - Переход со старого механизма автозапуска

    private var legacyAgentPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/LaunchAgents/com.dmitriy.batlimit.menu.plist")
    }

    private let legacyAgentLabel = "com.dmitriy.batlimit.menu"

    /// Убирает LaunchAgent, которым автозапуск делался раньше, и переносит
    /// намерение пользователя на SMAppService.
    private func migrateLegacyLoginAgent() {
        guard FileManager.default.fileExists(atPath: legacyAgentPath) else { return }

        // bootout убил бы нас, если этот процесс запущен самим агентом.
        if legacyAgentPID() != ProcessInfo.processInfo.processIdentifier {
            launchctl(["bootout", "gui/\(getuid())/\(legacyAgentLabel)"])
        }
        try? FileManager.default.removeItem(atPath: legacyAgentPath)

        if loginState == .off {
            try? SMAppService.mainApp.register()
        }
    }

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func legacyAgentPID() -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(legacyAgentLabel)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.contains("pid = ") }),
              let raw = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces),
              let pid = pid_t(raw) else { return nil }
        return pid
    }

    // MARK: - Построение меню

    private func buildMenu() {
        titleItem = disabledItem("…")
        menu.addItem(titleItem)
        phaseItem = disabledItem("")
        menu.addItem(phaseItem)

        warningItem = disabledItem("")
        warningItem.isHidden = true
        menu.addItem(warningItem)

        serviceItem = actionItem(L("menu.service.install"), #selector(openSettings))
        serviceItem.isHidden = true
        menu.addItem(serviceItem)

        updateItem = actionItem("", #selector(showPendingUpdate))
        updateItem.isHidden = true
        menu.addItem(updateItem)

        menu.addItem(.separator())

        chargingItem = NSMenuItem(title: L("menu.charging"), action: nil, keyEquivalent: "")
        chargingItem.submenu = buildChargingMenu()
        menu.addItem(chargingItem)

        energyItem = NSMenuItem(title: L("menu.energy"), action: nil, keyEquivalent: "")
        energyItem.submenu = buildEnergyMenu()
        menu.addItem(energyItem)

        menu.addItem(.separator())

        monitorItem = actionItem(L("menu.monitor"), #selector(openMonitor))
        menu.addItem(monitorItem)

        settingsItem = actionItem(L("menu.settings"), #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = actionItem(L("menu.quit"), #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func buildChargingMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        holdItem = actionItem(L("menu.charging.hold"), #selector(setHold))
        submenu.addItem(holdItem)
        chargeItem = actionItem(L("menu.charging.chargeTo", 80), #selector(chargeNow))
        submenu.addItem(chargeItem)
        autoItem = actionItem(L("menu.charging.auto", 30, 80), #selector(toggleAuto))
        submenu.addItem(autoItem)
        offItem = actionItem(L("menu.charging.off"), #selector(setOff))
        submenu.addItem(offItem)

        submenu.addItem(.separator())

        lowMenuItem = NSMenuItem(title: L("menu.charging.low"), action: nil, keyEquivalent: "")
        lowMenuItem.submenu = thresholdMenu([20, 25, 30, 35, 40, 50], #selector(setLow(_:)))
        submenu.addItem(lowMenuItem)

        highMenuItem = NSMenuItem(title: L("menu.charging.high"), action: nil, keyEquivalent: "")
        highMenuItem.submenu = thresholdMenu([60, 70, 75, 80, 90, 100], #selector(setHigh(_:)))
        submenu.addItem(highMenuItem)

        return submenu
    }

    private func buildEnergyMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for source in PowerSourceKey.allCases {
            submenu.addItem(sectionHeader(source == .battery ? L("menu.energy.battery")
                                                             : L("menu.energy.ac")))
            energyModeItems[source] = EnergyMode.allCases.map { mode in
                let item = actionItem(mode.localizedName, #selector(setEnergyMode(_:)))
                item.tag = energyTag(source, mode)
                submenu.addItem(item)
                return item
            }
            submenu.addItem(.separator())
        }

        submenu.addItem(actionItem(L("menu.energy.settings"), #selector(openBatterySettings)))
        return submenu
    }

    /// Номер пункта режима: источник и режим в одном числе — десятки
    /// за источник, единицы за значение `powermode`.
    private func energyTag(_ source: PowerSourceKey, _ mode: EnergyMode) -> Int {
        (source == .battery ? 0 : 10) + mode.pmsetValue
    }

    /// Заголовок блока в меню. Настоящие заголовки появились в macOS 14,
    /// на 13-й их заменяет неактивная строка.
    private func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14, *) {
            return NSMenuItem.sectionHeader(title: title)
        }
        return disabledItem(title)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func thresholdMenu(_ values: [Int], _ action: Selector) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for v in values {
            let item = NSMenuItem(title: L("menu.percent", v), action: action, keyEquivalent: "")
            item.target = self
            item.tag = v
            submenu.addItem(item)
        }
        return submenu
    }

    // MARK: - Обновление состояния

    private func refresh() {
        let cfg = Config.load()
        let installState = HelperInstaller.state(bundledVersion: daemonFingerprint)
        let installed = installState != .notInstalled
        let status = Status.load()
        let live = installed ? (status?.isFresh ?? false) : false
        // Служба ответила — дальше её молчание уже не «ещё не поднялась».
        if live { graceUntil = .distantPast }
        let starting = Date() < graceUntil
        // Заряд читаем сами: IORegistry прав не требует, и значок остаётся
        // честным, даже когда служба молчит.
        let battery = Battery.read()

        let plugged = battery?.isPluggedIn ?? status?.isPluggedIn ?? false
        let energy = EnergyModes.current()

        // Цвет значка — режим того источника, от которого ноутбук работает
        // сейчас: так же выбирает и сама macOS.
        applyIndicator(battery: battery, status: status, energy: energy[plugged ? .ac : .battery],
                       live: live, starting: starting)
        updateServiceItem(installState)
        updateChargingMenu(cfg: cfg, status: status, live: live)
        updateEnergyMenu(current: energy, live: live)

        guard let st = status, installed else {
            titleItem.title = installed
                ? (starting ? L("menu.service.starting") : L("menu.service.silent"))
                : L("menu.service.missing")
            phaseItem.title = installed ? "" : L("menu.service.unavailable")
            warningItem.isHidden = true
            return
        }

        titleItem.title = L("menu.title", st.percentage,
                            st.isPluggedIn ? L("source.ac") : L("source.battery"))
        if !live {
            phaseItem.title = starting ? L("menu.service.starting") : L("menu.service.silent")
        } else if let err = st.error {
            phaseItem.title = L("menu.error", err)
        } else {
            phaseItem.title = st.localizedPhase
        }

        // Системный лимит macOS — независимый от нас замок: он держит зарядку
        // своим битом и нашим SMC-ключом не открывается.
        let conflict = st.systemLimitActive && st.percentage < st.high
        warningItem.isHidden = !conflict
        if conflict {
            warningItem.title = L("menu.warning.systemLimit")
        }
    }

    private func updateServiceItem(_ state: HelperInstaller.InstallState) {
        switch state {
        case .ready:
            serviceItem.isHidden = true
        case .notInstalled:
            serviceItem.isHidden = false
            serviceItem.title = L("menu.service.install")
        case .outdated:
            serviceItem.isHidden = false
            serviceItem.title = L("menu.service.update")
        }
    }

    private func updateChargingMenu(cfg: Config, status: Status?, live: Bool) {
        // Пункты управления бессмысленны, пока служба не отвечает.
        for item in [holdItem, chargeItem, autoItem, offItem, lowMenuItem, highMenuItem] {
            item?.isEnabled = live
        }
        chargingItem.isEnabled = live

        let mode = status?.mode ?? cfg.mode
        holdItem.state = (mode == .hold) ? .on : .off
        autoItem.state = (mode == .auto) ? .on : .off
        offItem.state  = (mode == .off)  ? .on : .off
        autoItem.title = L("menu.charging.auto", cfg.low, cfg.high)

        let chargingNow = status?.chargeNow ?? false
        chargeItem.title = chargingNow ? L("menu.charging.chargingTo", cfg.high)
                                       : L("menu.charging.chargeTo", cfg.high)
        chargeItem.state = chargingNow ? .on : .off
        chargeItem.isEnabled = live && !chargingNow && (status?.percentage ?? 0) < cfg.high

        for item in lowMenuItem.submenu?.items ?? [] { item.state = (item.tag == cfg.low) ? .on : .off }
        for item in highMenuItem.submenu?.items ?? [] { item.state = (item.tag == cfg.high) ? .on : .off }
    }

    /// Режим энергии — системный переключатель: его меняют и в Настройках, и в
    /// Пункте управления. Текущее значение читаем сами (прав для этого не
    /// нужно), а менять умеет только служба — пока она молчит, показываем
    /// правду, но переключать не даём: просьбу некому выполнить.
    private func updateEnergyMenu(current: EnergyModePair, live: Bool) {
        for (source, items) in energyModeItems {
            for (mode, item) in zip(EnergyMode.allCases, items) {
                item.state = (current[source] == mode) ? .on : .off
                item.isEnabled = live
                item.isHidden = mode == .high && !supportsHighPower[source, default: false]
            }
        }
    }

    /// Возможности машины за время работы не меняются — спрашиваем один раз.
    private lazy var supportsHighPower: [PowerSourceKey: Bool] = Dictionary(
        uniqueKeysWithValues: PowerSourceKey.allCases.map { ($0, EnergyModes.supportsHigh(source: $0)) })

    private func applyIndicator(battery: BatteryInfo?, status: Status?, energy: EnergyMode?,
                                live: Bool, starting: Bool) {
        guard let button = statusItem.button else { return }

        let percentage = battery?.percentage ?? status?.percentage
        let plugged = battery?.isPluggedIn ?? status?.isPluggedIn ?? false
        let charging = battery?.isCharging ?? status?.isCharging ?? false

        let badge: BatteryGlyph.Badge
        if !live {
            // При входе в систему приложение стартует раньше службы. Тревожить
            // восклицательным знаком в это окно не за что: подождём и промолчим.
            badge = starting ? .none : .warning
            button.toolTip = starting ? L("icon.tooltip.starting") : L("icon.tooltip.silent")
        } else if let st = status {
            // Метку состояния можно выключить в настройках — кому она не нужна.
            // Тревожный «!» (служба молчит) остаётся выше, отдельной веткой:
            // это не рядовое состояние, а сигнал неполадки.
            if !AppPreferences.showBadge {
                badge = .none
            // Команда отправлена, но контроллер заряда её ещё не применил —
            // он перечитывает ключ раз в ~45–50 с. Показываем ожидание, а не
            // желаемый результат: иначе значок врёт целую минуту.
            } else if st.settling == true {
                badge = .settling
            } else if st.inhibited {
                badge = .hold
            } else if charging {
                badge = .charging
            } else if plugged {
                badge = .plugged
            } else {
                badge = .none
            }
            button.toolTip = L("icon.tooltip", st.percentage, st.localizedPhase)
                + (energy.map { "\n" + L("icon.tooltip.energy", $0.localizedName) } ?? "")
        } else {
            badge = .none
            button.toolTip = nil
        }

        button.image = BatteryGlyph.image(percentage: percentage ?? 0, badge: badge,
                                          tint: tint(percentage: percentage, plugged: plugged,
                                                     energy: energy))
        if AppPreferences.showPercentage {
            // Цифры моноширинные: иначе значок дёргался бы на каждом проценте.
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = percentage.map { L("menu.percent", $0) } ?? "—"
            button.imagePosition = .imageTrailing
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    /// Цвет батареи. Красный на исходе заряда и жёлтый в экономии — тот же
    /// язык, что у системного индикатора; синий у высокой производительности
    /// свой, в macOS для неё цвета нет. Заряд на исходе важнее режима:
    /// о нём и предупреждаем.
    private func tint(percentage: Int?, plugged: Bool, energy: EnergyMode?) -> BatteryGlyph.Tint {
        if let percentage, percentage <= 20, !plugged { return .critical }
        switch energy {
        case .low:  return .low
        case .high: return .high
        default:    return .normal
        }
    }

    // MARK: - Действия

    private func mutate(_ change: (inout Config) -> Void) {
        var cfg = Config.load()
        change(&cfg)
        do {
            try cfg.save()
        } catch {
            showError(L("alert.saveFailed.title"), L("alert.saveFailed.body", Paths.config, "\(error)"))
            return
        }
        refresh()
        // Демон опрашивает конфиг раз в секунду — обновимся, когда он ответит.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in self?.refresh() }
    }

    @objc private func setHold()   { mutate { $0.mode = .hold; $0.chargeNow = false } }
    @objc private func setOff()    { mutate { $0.mode = .off;  $0.chargeNow = false } }
    @objc private func chargeNow() { mutate { $0.chargeNow = true } }

    @objc private func toggleAuto() {
        let current = Config.load().mode
        mutate { $0.mode = (current == .auto) ? .off : .auto; $0.chargeNow = false }
    }

    @objc private func setEnergyMode(_ sender: NSMenuItem) {
        let source: PowerSourceKey = sender.tag >= 10 ? .ac : .battery
        guard let mode = EnergyMode.allCases.first(where: { energyTag(source, $0) == sender.tag })
        else { return }
        // Просьбу для другого источника, ещё не выполненную службой, не
        // затираем: два щелчка подряд должны сработать оба.
        mutate { cfg in
            var requests = cfg.energyModeRequests ?? EnergyModePair()
            requests[source] = mode
            cfg.energyModeRequests = requests
        }
    }

    @objc private func openBatterySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openMonitor() { monitorWindow.show() }

    @objc private func showPendingUpdate() { updates.checkNow() }

    private func updatePendingUpdateItem() {
        guard let version = updates.pendingVersion else {
            updateItem.isHidden = true
            return
        }
        updateItem.title = L("menu.update.available", version)
        updateItem.isHidden = false
    }

    @objc private func openSettings() { settingsWindow.show(actions: self) }

    @objc private func setLow(_ sender: NSMenuItem)  { mutate { $0.low = sender.tag } }
    @objc private func setHigh(_ sender: NSMenuItem) { mutate { $0.high = sender.tag } }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - Запросы из окна настроек

    var serviceInstallState: HelperInstaller.InstallState {
        HelperInstaller.state(bundledVersion: daemonFingerprint)
    }

    var loginItemEnabled: Bool { loginState != .off }
    var loginItemNeedsApproval: Bool { loginState == .needsApproval }

    func settingsInstallService() {
        // Машину проверяем до запроса пароля: ставить службу на Intel или на
        // Mac без батареи бессмысленно.
        let check = SystemCheck.run()
        guard check.isSupported else {
            showError(L("alert.unsupported.title"), check.summary)
            return
        }
        performInstall()
        settingsWindow.refresh()
    }

    func settingsUninstallService() {
        uninstallHelper()
        settingsWindow.refresh()
    }

    func settingsSetLoginItem(_ enabled: Bool) {
        toggleLoginItem(enabled)
    }

    func settingsOpenLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func settingsSetMagSafeLED(_ enabled: Bool) {
        mutate { $0.magsafeLED = enabled }
    }

    var automaticallyChecksForUpdates: Bool {
        get { updates.automaticallyChecks }
        set { updates.automaticallyChecks = newValue }
    }

    var canCheckForUpdates: Bool { updates.canCheck }

    func settingsCheckForUpdates() {
        updates.checkNow()
    }
}

// Второй экземпляр не нужен: включение автозапуска заставляет launchd поднять
// ещё одну копию, а две иконки в строке меню — это баг, а не фича.
let lockPath = NSHomeDirectory() + "/Library/Application Support/BatLimit.lock"
let lockDescriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
if lockDescriptor < 0 || flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
    exit(0)
}

let app = NSApplication.shared
let controller = MenuController()
app.delegate = controller
app.setActivationPolicy(.accessory)   // только строка меню, без Dock
app.run()
