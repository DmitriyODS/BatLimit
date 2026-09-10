import Foundation

public struct ProcessEnergy: Identifiable {
    public let id: Int          // pid
    public let name: String
    public let impact: Double   // «энергетическое воздействие», как в Мониторинге системы
}

/// Кто больше всех расходует батарею.
///
/// Данные берутся у `top`: он считает ту же метрику «энергетического
/// воздействия», что показывает Мониторинг системы, и не требует root
/// (в отличие от powermetrics).
public enum EnergyUsage {

    /// Занимает около двух секунд — вызывать только из фонового потока.
    public static func topProcesses(limit: Int = 8) -> [ProcessEnergy] {
        // Первая выборка top всегда нулевая: метрика считается как разница
        // между двумя замерами, поэтому просим две и читаем последнюю.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        // Порядок колонок важен: pid и power идут первыми, имя — последним.
        // Если имя окажется длинным, обрежется оно, а не метрика; при обратном
        // порядке разбор периодически ломался и список приходил пустым.
        process.arguments = ["-l", "2", "-o", "power", "-n", "\(limit)",
                             "-stats", "pid,power,command"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Имена процессов иногда содержат байты, не складывающиеся в UTF-8;
        // String(data:encoding:) на таком выводе возвращает nil и список
        // молча оказывался пустым. Этот инициализатор портит только плохие
        // символы, а не весь вывод.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        // Берём последний блок выборки, но если разобрать его не удалось —
        // откатываемся к предыдущему, чтобы разовый сбой не оставлял
        // панель с пустым списком.
        let headers = lines.indices.filter { lines[$0].hasPrefix("PID") }
        for header in headers.reversed() {
            let parsed = lines[(header + 1)...].compactMap(parse)
            if !parsed.isEmpty { return Array(parsed.prefix(limit)) }
        }
        return []
    }

    /// Строка вида `404    23.1  WindowServer`: pid, метрика, затем имя,
    /// которое само может содержать пробелы.
    private static func parse(_ line: Substring) -> ProcessEnergy? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 3,
              let pid = Int(fields[0]),
              let impact = Double(fields[1]) else { return nil }
        let name = fields[2...].joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return ProcessEnergy(id: pid, name: name, impact: impact)
    }
}
