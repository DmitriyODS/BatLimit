import AppKit
import Sparkle

// Обновления программы — через Sparkle, как у AlDente и большинства программ
// вне App Store. Раз в сутки Sparkle читает appcast.xml из последнего релиза на
// GitHub, сверяет подпись EdDSA архива и спрашивает, ставить ли новую версию.
//
// Подпись здесь обязательна, а не для галочки: сборка не подписана Developer ID,
// и без EdDSA любой, кто доберётся до релизов, подсунул бы свой код — а через
// обновление службы и root.

final class UpdateController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController!

    /// Версия, которую нашла фоновая проверка и которую пользователь ещё не видел.
    private(set) var pendingVersion: String? {
        didSet { if pendingVersion != oldValue { onPendingChange?() } }
    }

    /// Меню показывает найденную версию отдельным пунктом — сообщаем, когда
    /// его показать или убрать.
    var onPendingChange: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: self,
                                                  userDriverDelegate: self)
    }

    private var updater: SPUUpdater { controller.updater }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// Проверка уже идёт — вторую Sparkle не начнёт.
    var canCheck: Bool { updater.canCheckForUpdates }

    /// Проверить сейчас или вернуть в фокус уже найденное обновление.
    func checkNow() {
        AppWindows.opened(self)
        controller.checkForUpdates(nil)
    }

    // MARK: - Мягкие напоминания

    // Приложение живёт в строке меню, окон у него обычно нет. Окно обновления,
    // выскочившее посреди работы из фона, легко не заметить или принять за
    // навязчивое. Поэтому сразу его показываем только когда Sparkle считает
    // момент удачным (приложение только запустилось или пользователь отошёл),
    // а в остальное время — отмечаем пунктом в меню.

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            AppWindows.opened(self)
        } else {
            pendingVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        pendingVersion = nil
    }

    func standardUserDriverWillShowModalAlert() {
        // «Обновлений нет», ошибки загрузки — это тоже окна, и у приложения
        // из строки меню они иначе остались бы за чужими окнами.
        AppWindows.opened(self)
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingVersion = nil
        AppWindows.closed(self)
    }
}
