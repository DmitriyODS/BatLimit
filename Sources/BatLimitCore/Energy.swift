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

/// Сколько ватт каждый процесс тратит на вычисления.
///
/// Ядро ведёт для каждой задачи счётчик израсходованной энергии
/// (`ri_energy_nj` из `proc_pid_rusage`); берём разницу двух замеров и делим на
/// прошедшее время. Это настоящее измерение, а не пересчёт «энергетического
/// воздействия»: обе величины приходят из разных источников и между собой
/// не связаны.
///
/// Обход всех процессов занимает несколько миллисекунд (дороже всего обходятся
/// отказы на чужих) — на три порядка дешевле, чем запуск `top`, так что
/// опрашивать можно хоть каждую секунду.
///
/// Две оговорки, обе отражены в подписи под списком:
///
/// * считается только энергия процессорных ядер — экран, радиомодули и
///   накопитель ни за кем не числятся, поэтому сумма по процессам заметно
///   меньше общего потребления ноутбука;
/// * чужие процессы (root и другие пользователи — `WindowServer`,
///   `kernel_task`) читать не дают, для них мощность неизвестна.
public final class ProcessPower {
    private var previous: [Int32: UInt64] = [:]
    private var previousTime: Date

    public init() {
        previous = ProcessPower.snapshot()
        previousTime = Date()
    }

    /// Мощность по pid за время, прошедшее с прошлого вызова.
    /// Процессы, чей счётчик прочитать не удалось, в словарь не попадают.
    public func sample() -> [Int: Double] {
        let now = Date()
        let seconds = now.timeIntervalSince(previousTime)
        let current = ProcessPower.snapshot()
        // Слишком короткий промежуток превращает шум округления в киловатты.
        guard seconds >= 0.2 else { return [:] }

        var watts: [Int: Double] = [:]
        for (pid, energy) in current {
            // Счётчик только растёт; меньшее значение означает, что номер
            // достался новому процессу, — его первый замер пропускаем.
            guard let was = previous[pid], energy >= was else { continue }
            watts[Int(pid)] = Double(energy - was) / 1e9 / seconds
        }
        previous = current
        previousTime = now
        return watts
    }

    /// Накопленная энергия в наноджоулях по всем доступным процессам.
    private static func snapshot() -> [Int32: UInt64] {
        var pids = [Int32](repeating: 0, count: 8192)
        // Размер буфера задаётся в байтах, а возвращается уже число процессов,
        // а не байт: делить результат на размер Int32 не нужно.
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard count > 0 else { return [:] }

        var result: [Int32: UInt64] = [:]
        for pid in pids[0 ..< min(Int(count), pids.count)] where pid > 0 {
            if let energy = energy(of: pid) { result[pid] = energy }
        }
        return result
    }

    /// `ri_energy_nj` появился только в шестой версии структуры: на macOS,
    /// где её нет, вызов вернёт ошибку и мощность процессов останется
    /// неизвестной — панель покажет прочерки.
    private static func energy(of pid: Int32) -> UInt64? {
        var info = rusage_info_v6()
        let code = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            // proc_pid_rusage объявлен как `rusage_info_t *` (то есть `void **`),
            // но ждёт указатель на саму структуру — иначе пишет её содержимое
            // поверх восьми байт указателя.
            let slot = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V6, slot)
        }
        return code == 0 ? info.ri_energy_nj : nil
    }
}
