import Foundation

/// Одна точка истории заряда. Поля короткие: файл дописывается раз в минуту
/// и его размер важнее читаемости.
public struct HistoryPoint: Codable {
    public let t: Double   // unix-время
    public let p: Int      // процент заряда
    public let c: Bool     // идёт зарядка
    public let a: Bool     // подключён к сети

    public var date: Date { Date(timeIntervalSince1970: t) }

    public init(t: Double, p: Int, c: Bool, a: Bool) {
        self.t = t; self.p = p; self.c = c; self.a = a
    }
}

/// История заряда в JSONL: демон дописывает строки, приложение читает.
/// Построчный формат выбран ради дозаписи — перечитывать и переписывать
/// весь файл раз в минуту не нужно.
public enum History {
    public static var path: String { Paths.dir + "/history.jsonl" }

    /// 72 часа при записи раз в минуту.
    public static let maxPoints = 4320

    public static func append(_ point: HistoryPoint) {
        guard let data = try? JSONEncoder().encode(point),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: path)
        }
    }

    public static func load(hours: Double = 24) -> [HistoryPoint] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let cutoff = Date().timeIntervalSince1970 - hours * 3600
        let decoder = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let point = try? decoder.decode(HistoryPoint.self, from: Data(line.utf8)),
                  point.t >= cutoff else { return nil }
            return point
        }
    }

    /// Обрезает файл до `maxPoints` последних строк.
    public static func trim() {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxPoints else { return }
        let kept = lines.suffix(maxPoints).joined(separator: "\n") + "\n"
        try? kept.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}
