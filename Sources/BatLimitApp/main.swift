import AppKit
import ServiceManagement
import BatLimitCore

// BatLimit — иконка в строке меню. Сама по себе привилегий не имеет: пишет
// config.json и читает status.json. Всё, что касается SMC, делает служба
// batlimitd, которую приложение устанавливает при первом запуске.

final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let menu = NSMenu()

    /// До этого момента молчание службы считаем нормальным. При входе в систему
    /// login item поднимается раньше LaunchDaemon — на этой машине разрыв
    /// доходил до 16 секунд, и всё это время в строке меню висел «не отвечает».
    private var graceUntil = Date().addingTimeInterval(45)

    private var titleItem: NSMenuItem!
    private var phaseItem: NSMenuItem!
    private var cycleItem: NSMenuItem!
    private var warningItem: NSMenuItem!
    private var installItem: NSMenuItem!
    private var holdItem: NSMenuItem!
    private var chargeItem: NSMenuItem!
    private var autoItem: NSMenuItem!
    private var offItem: NSMenuItem!
    private var lowMenuItem: NSMenuItem!
    private var highMenuItem: NSMenuItem!
    private var monitorItem: NSMenuItem!
    private var ledItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private let monitorWindow = MonitorWindowController()
    private var footerItem: NSMenuItem!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev"
    }

    /// Чем помечена установленная служба: отпечатком её бинарника.
    /// Считается один раз: файл за время работы приложения не меняется,
    /// а SHA-256 по нему на каждом обновлении меню — это лишнее чтение диска.
    private lazy var daemonFingerprint: String = {
        resource("batlimitd").flatMap { HelperInstaller.fingerprint(ofFileAt: $0) } ?? version
    }()
    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

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
        updateLoginItem()
        refresh()

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

    /// Открытое меню перерисовываем сразу, не дожидаясь очередного тика.
    func menuWillOpen(_ menu: NSMenu) {
        updateLoginItem()
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
            showError("BatLimit не поддерживает этот Mac", check.summary)
            return
        }

        switch state {
        case .ready:
            return

        case .notInstalled:
            let alert = NSAlert()
            alert.messageText = "Установить службу BatLimit?"
            alert.informativeText = """
                Чтобы управлять зарядкой, нужна фоновая служба с правами \
                администратора — она единственная обращается к контроллеру питания.

                Пароль спросят один раз. Удалить службу можно из этого же меню.
                """
            alert.addButton(withTitle: "Установить")
            alert.addButton(withTitle: "Не сейчас")
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performInstall()

        case .outdated:
            let alert = NSAlert()
            alert.messageText = "Обновить службу BatLimit?"
            alert.informativeText = """
                Установлена служба от другой сборки приложения. \
                Обновление займёт пару секунд и потребует пароль администратора.
                """
            alert.addButton(withTitle: "Обновить")
            alert.addButton(withTitle: "Позже")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performInstall()
        }
    }

    @objc private func installHelper() {
        performInstall()
    }

    private func performInstall() {
        guard let script = resource("install-helper.sh"), let daemon = resource("batlimitd") else {
            showError("Приложение собрано неполностью",
                      "Внутри бандла нет install-helper.sh или batlimitd.")
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
            showError("Не удалось установить службу", "\(error)")
        }
        refresh()
    }

    @objc private func uninstallHelper() {
        let alert = NSAlert()
        alert.messageText = "Удалить службу BatLimit?"
        alert.informativeText = """
            Зарядка вернётся в обычный режим. Само приложение останется — \
            службу можно поставить снова из меню.
            """
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let script = resource("uninstall-helper.sh") else {
            showError("Приложение собрано неполностью", "Внутри бандла нет uninstall-helper.sh.")
            return
        }
        do {
            try HelperInstaller.uninstall(scriptPath: script)
        } catch HelperInstaller.InstallError.cancelled {
            return
        } catch {
            showError("Не удалось удалить службу", "\(error)")
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

    /// Состояние автозапуска спрашиваем у launchd только когда оно нужно на
    /// экране: `SMAppService.status` — синхронный XPC, и в цикле обновления
    /// он оказывался на главном потоке дважды в секунду.
    private func updateLoginItem() {
        let state = loginState
        loginItem.state = (state == .off) ? .off : .on
        loginItem.title = (state == .needsApproval)
            ? "Запускать при входе (нужно разрешение)"
            : "Запускать при входе"
    }

    @objc private func toggleLoginItem() {
        do {
            if loginState == .off {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    promptLoginApproval()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError("Не удалось изменить автозапуск", error.localizedDescription)
        }
        updateLoginItem()
        refresh()
    }

    private func promptLoginApproval() {
        let alert = NSAlert()
        alert.messageText = "Разреши запуск при входе"
        alert.informativeText = """
            macOS требует подтверждения: включи BatLimit в разделе             «Элементы входа» системных настроек.
            """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
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

        cycleItem = disabledItem("")
        cycleItem.isHidden = true
        menu.addItem(cycleItem)

        warningItem = disabledItem("")
        warningItem.isHidden = true
        menu.addItem(warningItem)

        installItem = NSMenuItem(title: "Установить службу…",
                                 action: #selector(installHelper), keyEquivalent: "")
        installItem.target = self
        installItem.isHidden = true
        menu.addItem(installItem)

        monitorItem = actionItem("Панель мониторинга…", #selector(openMonitor))
        menu.addItem(monitorItem)

        menu.addItem(.separator())

        holdItem = actionItem("Не заряжать", #selector(setHold))
        menu.addItem(holdItem)
        chargeItem = actionItem("Зарядить до 80 %", #selector(chargeNow))
        menu.addItem(chargeItem)

        menu.addItem(.separator())

        autoItem = actionItem("Авто: держать 30–80 %", #selector(toggleAuto))
        menu.addItem(autoItem)

        lowMenuItem = NSMenuItem(title: "Нижний порог", action: nil, keyEquivalent: "")
        lowMenuItem.submenu = thresholdMenu([20, 25, 30, 35, 40, 50], #selector(setLow(_:)))
        menu.addItem(lowMenuItem)

        highMenuItem = NSMenuItem(title: "Верхний порог", action: nil, keyEquivalent: "")
        highMenuItem.submenu = thresholdMenu([60, 70, 75, 80, 90, 100], #selector(setHigh(_:)))
        menu.addItem(highMenuItem)

        menu.addItem(.separator())

        offItem = actionItem("Заряжать как обычно", #selector(setOff))
        menu.addItem(offItem)

        menu.addItem(.separator())

        ledItem = actionItem("Зелёный индикатор MagSafe", #selector(toggleLED))
        menu.addItem(ledItem)

        loginItem = actionItem("Запускать при входе", #selector(toggleLoginItem))
        menu.addItem(loginItem)

        let removeItem = actionItem("Удалить службу…", #selector(uninstallHelper))
        menu.addItem(removeItem)

        footerItem = disabledItem("")
        menu.addItem(footerItem)

        let quit = actionItem("Выйти", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
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
            let item = NSMenuItem(title: "\(v) %", action: action, keyEquivalent: "")
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

        // Пункты управления бессмысленны, пока служба не отвечает.
        for item in [holdItem, chargeItem, autoItem, offItem, lowMenuItem, highMenuItem] {
            item?.isEnabled = live
        }
        // Пункт остаётся доступным и когда служба устарела: иначе отложенное
        // обновление уже нечем было бы запустить.
        switch installState {
        case .ready:
            installItem.isHidden = true
        case .notInstalled:
            installItem.isHidden = false
            installItem.title = "Установить службу…"
        case .outdated:
            installItem.isHidden = false
            installItem.title = "Обновить службу…"
        }
        ledItem.state = cfg.magsafeLED ? .on : .off
        ledItem.isEnabled = live

        guard let st = status, installed else {
            applyIndicator(nil, live: false, starting: starting)
            titleItem.title = installed
                ? (starting ? "Служба запускается…" : "Служба не отвечает")
                : "Служба не установлена"
            phaseItem.title = installed ? "" : "Управление зарядкой недоступно"
            cycleItem.isHidden = true
            warningItem.isHidden = true
            footerItem.title = "BatLimit \(shortVersion)"
            return
        }

        applyIndicator(st, live: live, starting: starting)

        titleItem.title = "\(st.percentage) % · \(st.isPluggedIn ? "от сети" : "от батареи")"
        if !live {
            phaseItem.title = starting ? "служба запускается…" : "служба не отвечает"
        } else if let err = st.error {
            phaseItem.title = "ошибка: \(err)"
        } else {
            phaseItem.title = st.phase
        }

        if let cycles = st.cycleCount {
            cycleItem.title = "Циклов зарядки: \(cycles)"
            cycleItem.isHidden = false
        } else {
            cycleItem.isHidden = true
        }

        // Системный лимит macOS — независимый от нас замок: он держит зарядку
        // своим битом и нашим SMC-ключом не открывается.
        let conflict = st.systemLimitActive && st.percentage < st.high
        warningItem.isHidden = !conflict
        if conflict {
            warningItem.title = "⚠︎ Зарядку держит системный лимит macOS"
        }

        holdItem.state = (st.mode == .hold) ? .on : .off
        autoItem.state = (st.mode == .auto) ? .on : .off
        offItem.state  = (st.mode == .off)  ? .on : .off
        autoItem.title = "Авто: держать \(cfg.low)–\(cfg.high) %"
        chargeItem.title = st.chargeNow ? "Заряжаю до \(cfg.high) %…" : "Зарядить до \(cfg.high) %"
        chargeItem.isEnabled = live && !st.chargeNow && st.percentage < cfg.high

        for item in lowMenuItem.submenu?.items ?? [] { item.state = (item.tag == cfg.low) ? .on : .off }
        for item in highMenuItem.submenu?.items ?? [] { item.state = (item.tag == cfg.high) ? .on : .off }

        footerItem.title = "BatLimit \(shortVersion) · \(st.api)"
    }

    /// В строке меню показываем только то, что делает BatLimit. Процент заряда
    /// не дублируем — его уже показывает системный индикатор батареи.
    private func applyIndicator(_ st: Status?, live: Bool, starting: Bool) {
        guard let button = statusItem.button else { return }
        button.title = ""

        guard let st, live else {
            // При входе в систему приложение стартует раньше службы. Тревожить
            // треугольником в это окно не за что: подождём и промолчим.
            button.image = symbol(starting ? "battery.100percent" : "exclamationmark.triangle")
            button.appearsDisabled = starting
            button.toolTip = starting ? "BatLimit: служба запускается…"
                                      : "BatLimit: служба не отвечает"
            return
        }

        // Команда отправлена, но контроллер заряда её ещё не применил —
        // он перечитывает ключ раз в ~45–50 с. Показываем ожидание, а не
        // желаемый результат: иначе значок врёт целую минуту.
        guard st.settling != true else {
            button.image = symbol("hourglass")
            button.appearsDisabled = false
            button.toolTip = "BatLimit · \(st.percentage) % · \(st.phase)"
            return
        }

        switch st.mode {
        case .off:
            // Не вмешиваемся — значок приглушён, чтобы не притягивать взгляд.
            button.image = symbol("battery.100percent")
            button.appearsDisabled = true
            button.toolTip = "BatLimit: не вмешивается"
        case .hold, .auto:
            button.image = symbol(st.inhibited ? "pause.fill" : "bolt.fill")
            button.appearsDisabled = false
            button.toolTip = "BatLimit · \(st.percentage) % · \(st.phase)"
        }
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    // MARK: - Действия

    private func mutate(_ change: (inout Config) -> Void) {
        var cfg = Config.load()
        change(&cfg)
        do {
            try cfg.save()
        } catch {
            showError("Не удалось сохранить настройку",
                      "\(Paths.config): \(error)\n\nПопробуй переустановить службу из меню.")
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

    @objc private func toggleLED() {
        let current = Config.load().magsafeLED
        mutate { $0.magsafeLED = !current }
    }

    @objc private func openMonitor() { monitorWindow.show() }

    @objc private func setLow(_ sender: NSMenuItem)  { mutate { $0.low = sender.tag } }
    @objc private func setHigh(_ sender: NSMenuItem) { mutate { $0.high = sender.tag } }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
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
