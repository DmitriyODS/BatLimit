import AppKit

/// Кто из окон сейчас открыт.
///
/// Приложение живёт в строке меню (`.accessory`): у окна такого приложения не
/// было бы ни фокуса, ни строки меню, поэтому на время показа становимся
/// обычным. Считать открытые окна по `NSApp.windows` нельзя — там же лежит
/// окно самого значка в строке меню, и приложение навсегда осталось бы в Dock.
enum AppWindows {
    private static var open: Set<ObjectIdentifier> = []

    static func opened(_ owner: AnyObject) {
        open.insert(ObjectIdentifier(owner))
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed(_ owner: AnyObject) {
        open.remove(ObjectIdentifier(owner))
        guard open.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
