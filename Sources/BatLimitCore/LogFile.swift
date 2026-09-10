import Foundation

/// Ротация журнала службы.
///
/// Журнал открывает не демон, а launchd: `StandardOutPath` и `StandardErrorPath`
/// в plist'е перенаправляют в него stdout и stderr. Отсюда два следствия.
///
/// Переименовать файл нельзя — так делает `newsyslog`, и именно поэтому он
/// здесь не годится: дескриптор launchd останется на прежнем inode, демон
/// продолжит писать в уже удалённый файл, а новый так и будет лежать пустым.
/// Сообщить launchd, что файл пора переоткрыть, нечем.
///
/// Зато обрезать на месте безопасно: inode тот же, а launchd открывает файл
/// с `O_APPEND` — проверено отдельным launchd-агентом: после `truncate` до
/// нуля следующая запись легла со смещения 0, без дыры из нулей. Поэтому
/// ротация здесь — «скопировать и обрезать»: прошлое поколение уезжает
/// в `.1`, текущий файл обнуляется.
public enum LogFile {
    /// Порог ротации. При обычной работе демон пишет несколько строк в сутки,
    /// так что до него не доходит вовсе; порог нужен на случай, когда что-то
    /// пошло не так и в журнал полетело по строке в секунду.
    public static let maxBytes = 1_048_576

    /// Прошлое поколение журнала. Держим ровно одно: две копии по мегабайту —
    /// потолок, который не жалко занять на системном диске.
    public static var archivePath: String { Paths.log + ".1" }

    /// Размер файла, байт.
    public static func size(of path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? Int) ?? 0
    }

    /// Обрезает журнал службы, если он перерос порог. Возвращает размер, который
    /// был на момент ротации, или nil — если ротировать было нечего.
    @discardableResult
    public static func rotateIfNeeded() -> Int? {
        rotate(path: Paths.log, archivePath: archivePath, maxBytes: maxBytes)
    }

    /// Сама ротация. Вынесена с путями в параметрах, чтобы её можно было
    /// прогнать на временном файле, а не только на `/var/log`.
    @discardableResult
    public static func rotate(path: String, archivePath: String, maxBytes: Int) -> Int? {
        let current = size(of: path)
        guard current > maxBytes else { return nil }

        let fm = FileManager.default
        try? fm.removeItem(atPath: archivePath)
        // Скопировать может и не выйти (нет места, права). Обрезать всё равно
        // нужно: потерянный журнал неприятен, забитый диск — хуже.
        try? fm.copyItem(atPath: path, toPath: archivePath)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: archivePath)

        guard truncate(path, 0) == 0 else { return nil }
        return current
    }
}
