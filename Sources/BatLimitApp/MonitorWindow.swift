import AppKit
import SwiftUI
import Charts
import BatLimitCore

// Панель мониторинга: заряд во времени, состояние батареи и главные
// потребители энергии. Данные читаются напрямую из IORegistry и из истории,
// которую ведёт служба, — привилегии для этого не нужны.

final class MonitorModel: ObservableObject {
    @Published var battery: BatteryInfo?
    @Published var status: Status?
    @Published var history: [HistoryPoint] = []
    @Published var processes: [ProcessEnergy] = []
    @Published var isLoadingProcesses = false

    @Published var hours: Double = 24 {
        didSet { reloadHistory() }
    }

    private var timer: Timer?
    private var processTick = 0

    func start() {
        refresh()
        reloadHistory()
        reloadProcesses()
        // Режим .common, а не .default: иначе панель замирает на всё время,
        // пока крутят колесо или тянут за край окна.
        let ticker = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isLoadingProcesses = false
    }

    /// Насколько назад реально хватает истории.
    var historySpan: TimeInterval {
        guard let first = history.first, let last = history.last else { return 0 }
        return last.t - first.t
    }

    private func tick() {
        refresh()
        reloadHistory()
        // top отнимает пару секунд, поэтому опрашиваем его реже остального.
        processTick += 1
        if processTick % 4 == 0 { reloadProcesses() }
    }

    private func refresh() {
        battery = Battery.read()
        status = Status.load()
    }

    private func reloadHistory() {
        history = History.load(hours: hours)
    }

    private func reloadProcesses() {
        guard !isLoadingProcesses else { return }
        isLoadingProcesses = true
        // top блокирует поток на пару секунд — уводим его с главного.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = EnergyUsage.topProcesses(limit: 8)
            DispatchQueue.main.async {
                self?.processes = list
                self?.isLoadingProcesses = false
            }
        }
    }

    /// Отрезки времени, когда шла зарядка, — подсветка под графиком.
    var chargingSpans: [(start: Date, end: Date)] {
        var spans: [(Date, Date)] = []
        var start: Date?
        for point in history {
            if point.c, start == nil {
                start = point.date
            } else if !point.c, let began = start {
                spans.append((began, point.date))
                start = nil
            }
        }
        if let began = start, let last = history.last {
            spans.append((began, last.date))
        }
        return spans
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                tiles
                chartSection
                processSection
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(model.battery?.percentage ?? 0) %")
                .font(.system(size: 42, weight: .medium, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status?.phase ?? "служба не отвечает")
                    .font(.headline)
                if let remaining = remainingText {
                    Text(remaining).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var remainingText: String? {
        guard let minutes = model.status?.minutesRemaining else { return nil }
        let text = minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
        return (model.battery?.isCharging ?? false)
            ? "до полного заряда: \(text)"
            : "работы осталось: \(text)"
    }

    // MARK: - Плитки

    private var tiles: some View {
        HStack(spacing: 12) {
            tile("Циклов", model.battery?.cycleCount.map(String.init) ?? "—")
            tile("Здоровье", model.battery?.health.map { String(format: "%.0f %%", $0) } ?? "—")
            tile("Ёмкость", model.battery?.maxCapacity.map { "\($0) мА·ч" } ?? "—")
            tile("Температура",
                 model.battery?.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
        }
    }

    private func tile(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - График

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Заряд во времени").font(.headline)
                Spacer()
                Picker("", selection: $model.hours) {
                    Text("6 ч").tag(6.0)
                    Text("24 ч").tag(24.0)
                    Text("3 дня").tag(72.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }

            if model.history.count < 2 {
                Text("Служба собирает данные раз в минуту — график появится через несколько минут работы.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            } else {
                chart.frame(height: 220)
                Text(historyNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var historyNote: String {
        let hours = model.historySpan / 3600
        let collected = hours >= 1
            ? String(format: "%.0f ч", hours)
            : "\(Int(model.historySpan / 60)) мин"
        return model.historySpan < model.hours * 3600
            ? "Истории пока за \(collected) — служба дописывает точку раз в минуту."
            : "Истории за \(collected)."
    }

    /// Ось времени задаётся выбранным диапазоном, а не тем, сколько точек
    /// успело накопиться: иначе переключение 6 ч / 24 ч / 3 дня не давало
    /// видимого эффекта, пока история короткая.
    private var xDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-model.hours * 3600)...now
    }

    private var chart: some View {
        Chart {
            // Полосы под периодами, когда батарея заряжалась
            ForEach(Array(model.chargingSpans.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("с", span.start),
                              xEnd: .value("по", span.end),
                              yStart: .value("низ", 0),
                              yEnd: .value("верх", 100))
                    .foregroundStyle(.green.opacity(0.12))
            }

            ForEach(model.history, id: \.t) { point in
                AreaMark(x: .value("Время", point.date),
                         y: .value("Заряд", point.p))
                    .foregroundStyle(.linearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)],
                        startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)

                LineMark(x: .value("Время", point.date),
                         y: .value("Заряд", point.p))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
            }

            if let low = model.status?.low, let high = model.status?.high,
               model.status?.mode == .auto {
                RuleMark(y: .value("Нижний порог", low))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.orange.opacity(0.7))
                RuleMark(y: .value("Верхний порог", high))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.orange.opacity(0.7))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) %") } }
            }
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: model.hours > 24
                             ? .dateTime.day().month(.abbreviated).hour()
                             : .dateTime.hour().minute())
                    }
                }
            }
        }
    }

    // MARK: - Потребители энергии

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Больше всего расходуют батарею").font(.headline)
                if model.isLoadingProcesses {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if model.processes.isEmpty {
                Text(model.isLoadingProcesses ? "Собираю данные…" : "Данные пока не получены — повторю через несколько секунд.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.processes) { process in
                        processRow(process)
                    }
                }
            }

            Text("«Энергетическое воздействие» — та же метрика, что в Мониторинге системы: "
                 + "относительная нагрузка процесса на батарею.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func processRow(_ process: ProcessEnergy) -> some View {
        let maxImpact = model.processes.map(\.impact).max() ?? 1
        return HStack(spacing: 10) {
            Text(process.name)
                .lineLimit(1)
                .frame(width: 180, alignment: .leading)
            GeometryReader { geometry in
                let ratio = maxImpact > 0 ? process.impact / maxImpact : 0
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(2, geometry.size.width * ratio))
            }
            .frame(height: 14)
            Text(String(format: "%.1f", process.impact))
                .monospacedDigit()
                .font(.callout)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Окно

final class MonitorWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = MonitorModel()

    func show() {
        if let window {
            activate(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Батарея — BatLimit"
        window.contentView = NSHostingView(rootView: MonitorView(model: model))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        model.start()
        activate(window)
    }

    private func activate(_ window: NSWindow) {
        // Приложение живёт в строке меню (.accessory), у такого окна не было бы
        // ни фокуса, ни строки меню — на время показа становимся обычным.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
