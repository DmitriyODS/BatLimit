import AppKit
import SwiftUI
import BatLimitCore

// Окно настроек. Сюда убрано всё, что настраивают один раз и потом забывают:
// автозапуск, вид значка, индикатор MagSafe и сама служба. В меню строки
// остались только те, за которыми туда и заходят, — заряд и энергия.

/// Что окно настроек умеет попросить у приложения. Установка службы и
/// автозапуск живут в `MenuController`: там же запрос пароля и диалоги.
protocol SettingsActions: AnyObject {
    var serviceInstallState: HelperInstaller.InstallState { get }
    var loginItemEnabled: Bool { get }
    var loginItemNeedsApproval: Bool { get }

    func settingsInstallService()
    func settingsUninstallService()
    func settingsSetLoginItem(_ enabled: Bool)
    func settingsOpenLoginItems()
    func settingsSetMagSafeLED(_ enabled: Bool)
}

final class SettingsModel: ObservableObject {
    @Published private(set) var installState: HelperInstaller.InstallState = .notInstalled
    @Published private(set) var live = false
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var magsafeLED = true
    @Published private(set) var magsafeAvailable = true
    @Published private(set) var api: String?

    weak var actions: SettingsActions?
    private var timer: Timer?

    var showPercentage: Bool {
        get { AppPreferences.showPercentage }
        set {
            guard newValue != AppPreferences.showPercentage else { return }
            objectWillChange.send()
            AppPreferences.showPercentage = newValue
        }
    }

    func start() {
        refresh()
        // Режим .common: иначе состояние службы замирало бы на время
        // перетаскивания окна и работы с выпадающими списками.
        let ticker = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let cfg = Config.load()
        let status = Status.load()
        installState = actions?.serviceInstallState ?? .notInstalled
        live = installState != .notInstalled && (status?.isFresh ?? false)
        loginEnabled = actions?.loginItemEnabled ?? false
        loginNeedsApproval = actions?.loginItemNeedsApproval ?? false
        magsafeLED = cfg.magsafeLED
        // Пока служба молчит, о разъёме судить не по чему — не пугаем
        // пользователя надписью «нет MagSafe» на машине, где он есть.
        magsafeAvailable = status?.magsafeLEDAvailable ?? true
        api = live ? status?.api : nil
    }

    func setMagSafeLED(_ enabled: Bool) {
        magsafeLED = enabled
        actions?.settingsSetMagSafeLED(enabled)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            generalSection
            magsafeSection
            serviceSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 500)
    }

    // MARK: - Основные

    private var generalSection: some View {
        Section(L("settings.section.general")) {
            Toggle(L("settings.loginItem"), isOn: Binding(
                get: { model.loginEnabled },
                set: { model.actions?.settingsSetLoginItem($0) }))

            if model.loginNeedsApproval {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("settings.loginItem.needsApproval"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("settings.loginItem.open")) {
                        model.actions?.settingsOpenLoginItems()
                    }
                }
            }

            Toggle(L("settings.showPercentage"), isOn: Binding(
                get: { model.showPercentage },
                set: { model.showPercentage = $0 }))
            Text(L("settings.showPercentage.note"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - MagSafe

    private var magsafeSection: some View {
        Section(L("settings.section.magsafe")) {
            Toggle(L("settings.magsafeLED"), isOn: Binding(
                get: { model.magsafeLED },
                set: { model.setMagSafeLED($0) }))
                .disabled(!model.magsafeAvailable || !model.live)
            Text(model.magsafeAvailable ? L("settings.magsafeLED.note")
                                        : L("settings.magsafe.unavailable"))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Служба

    private var serviceSection: some View {
        Section(L("settings.section.service")) {
            LabeledContent(L("settings.service.state")) {
                Text(serviceStateText).foregroundStyle(serviceStateColor)
            }

            HStack {
                switch model.installState {
                case .ready:
                    Button(L("settings.service.reinstall")) {
                        model.actions?.settingsInstallService()
                    }
                case .notInstalled:
                    Button(L("settings.service.install")) {
                        model.actions?.settingsInstallService()
                    }
                    .keyboardShortcut(.defaultAction)
                case .outdated:
                    Button(L("settings.service.update")) {
                        model.actions?.settingsInstallService()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button(L("settings.service.remove"), role: .destructive) {
                    model.actions?.settingsUninstallService()
                }
                .disabled(model.installState == .notInstalled)
            }

            Text(L("settings.service.note"))
                .font(.callout).foregroundStyle(.secondary)

            LabeledContent(L("settings.version"), value: SettingsView.versionText)
            if let api = model.api {
                LabeledContent(L("settings.api"), value: api)
            }
        }
    }

    private var serviceStateText: String {
        switch model.installState {
        case .notInstalled: return L("settings.service.missing")
        case .outdated:     return L("settings.service.outdated")
        case .ready:        return model.live ? L("settings.service.ready")
                                              : L("settings.service.silent")
        }
    }

    private var serviceStateColor: Color {
        switch model.installState {
        case .notInstalled: return .secondary
        case .outdated:     return .orange
        case .ready:        return model.live ? .green : .orange
        }
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return L("settings.version.value", short, build)
    }
}

// MARK: - Окно

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = SettingsModel()

    func show(actions: SettingsActions) {
        model.actions = actions
        model.refresh()

        if let window {
            activate(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = L("settings.title")
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        model.start()
        activate(window)
    }

    /// Состояние службы меняется по кнопке из этого же окна — обновляем,
    /// не дожидаясь очередного тика.
    func refresh() {
        model.refresh()
    }

    private func activate(_ window: NSWindow) {
        AppWindows.opened(self)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        window = nil
        AppWindows.closed(self)
    }
}
