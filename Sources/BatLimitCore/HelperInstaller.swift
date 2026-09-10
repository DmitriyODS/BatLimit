import Foundation
import CryptoKit

/// Установка привилегированной службы (LaunchDaemon).
///
/// Developer ID у сборки нет, поэтому SMAppService/SMJobBless неприменимы —
/// службу ставит shell-скрипт из бандла, запущенный через системный запрос
/// пароля администратора. Пароль спрашивается один раз, при первом запуске.
public enum HelperInstaller {

    public enum InstallState: Equatable {
        case notInstalled
        case outdated(installed: String, bundled: String)
        case ready
    }

    public enum InstallError: Error, CustomStringConvertible {
        case scriptMissing(String)
        case cancelled
        case failed(String)

        public var description: String {
            switch self {
            case .scriptMissing(let p): return "в приложении не найден файл \(p)"
            case .cancelled:            return "установка отменена"
            case .failed(let m):        return m
            }
        }
    }

    public static var installedVersion: String? {
        guard let raw = try? String(contentsOfFile: Paths.version, encoding: .utf8) else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Отпечаток бинарника демона. Сверяем именно его, а не версию сборки:
    /// иначе правка одного лишь интерфейса заставляла бы переустанавливать
    /// службу и снова спрашивать пароль.
    public static func fingerprint(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func state(bundledVersion: String) -> InstallState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.daemon), fm.fileExists(atPath: Paths.plist) else {
            return .notInstalled
        }
        guard let installed = installedVersion else {
            return .outdated(installed: "неизвестна", bundled: bundledVersion)
        }
        return installed == bundledVersion
            ? .ready
            : .outdated(installed: installed, bundled: bundledVersion)
    }

    /// Ставит или обновляет службу. Показывает системный запрос пароля.
    public static func install(scriptPath: String, daemonPath: String, version: String) throws {
        try runPrivileged([scriptPath, daemonPath, version])
    }

    /// Удаляет службу и все её файлы. Скрипт сначала возвращает обычную зарядку.
    public static func uninstall(scriptPath: String) throws {
        try runPrivileged([scriptPath])
    }

    // MARK: - Внутреннее

    private static func runPrivileged(_ argv: [String]) throws {
        guard let script = argv.first, FileManager.default.fileExists(atPath: script) else {
            throw InstallError.scriptMissing(argv.first ?? "")
        }
        let command = argv.map(shellQuote).joined(separator: " ")
        let source = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"

        var errorInfo: NSDictionary?
        guard let apple = NSAppleScript(source: source) else {
            throw InstallError.failed("не удалось подготовить запрос прав")
        }
        apple.executeAndReturnError(&errorInfo)

        if let info = errorInfo {
            // -128 = пользователь нажал «Отмена» в окне ввода пароля
            if (info[NSAppleScript.errorNumber] as? Int) == -128 {
                throw InstallError.cancelled
            }
            let message = info[NSAppleScript.errorMessage] as? String ?? "\(info)"
            throw InstallError.failed(message)
        }
    }

    /// Путь попадает в shell — оборачиваем в одинарные кавычки.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// …а вся команда целиком — ещё и в строковый литерал AppleScript.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
