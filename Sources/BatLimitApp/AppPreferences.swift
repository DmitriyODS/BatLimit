import Foundation

/// Настройки самого приложения — то, что не влияет на зарядку и потому не
/// касается службы: вид значка в строке меню. Живут в UserDefaults
/// пользователя, а не в config.json, который читает root.
enum AppPreferences {
    private static let showPercentageKey = "showPercentage"

    /// Показывать ли процент заряда текстом рядом со значком.
    static var showPercentage: Bool {
        get {
            // Ключа нет — значит настройку не трогали: процент показываем,
            // ради него значок и заменяет системный.
            UserDefaults.standard.object(forKey: showPercentageKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: showPercentageKey)
            NotificationCenter.default.post(name: .appPreferencesChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let appPreferencesChanged = Notification.Name("BatLimitAppPreferencesChanged")
}
