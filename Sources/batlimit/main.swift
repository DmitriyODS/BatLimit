import Foundation
import BatLimitCore

// CLI batlimit. Привилегий не имеет: только правит config.json и читает status.json.

let isTTY = isatty(fileno(stdout)) == 1
func style(_ s: String, _ code: String) -> String { isTTY ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func bold(_ s: String) -> String { style(s, "1") }
func dim(_ s: String) -> String { style(s, "2") }
func green(_ s: String) -> String { style(s, "32") }
func yellow(_ s: String) -> String { style(s, "33") }
func red(_ s: String) -> String { style(s, "31") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((red("Ошибка: ") + message + "\n").data(using: .utf8)!)
    exit(1)
}

func usage() {
    print("""
    \(bold("batlimit")) — ограничитель зарядки батареи

    \(bold("Команды:"))
      status                 текущее состояние (по умолчанию)
      hold                   не заряжать батарею
      charge                 зарядить сейчас до верхнего порога
      auto [низ] [верх]      авто-режим: держать заряд в коридоре
      off                    отключить управление, заряжать как обычно
      limits <низ> <верх>    изменить пороги, не меняя режим
      check                  подходит ли этот Mac
      smc <ключ>             прочитать SMC-ключ (диагностика)

    \(bold("Примеры:"))
      batlimit hold          не заряжать, пока не скажу
      batlimit auto 30 80    разряжать до 30%, заряжать до 80%, по кругу
      batlimit charge        разово дозарядить до верхнего порога
    """)
}

func requireDaemon() {
    guard let st = Status.load(), st.isFresh else {
        FileHandle.standardError.write((yellow("Предупреждение: ")
            + "демон batlimitd не отвечает — команда записана, но применится "
            + "только после его запуска.\nЗапустить: sudo launchctl kickstart -k system/"
            + Paths.label + "\n").data(using: .utf8)!)
        return
    }
    _ = st
}

/// Меняем конфиг и ждём, пока демон подтвердит применение.
func update(_ mutate: (inout Config) -> Void, waitForChange: Bool = true) {
    var cfg = Config.load()
    mutate(&cfg)
    do {
        try cfg.save()
    } catch {
        fail("не удалось записать \(Paths.config): \(error)\n"
            + "Открой BatLimit в строке меню и установи службу.")
    }
    requireDaemon()

    if waitForChange {
        // Демон опрашивает конфиг раз в секунду; ждём до 3 с, чтобы показать
        // уже применённое состояние, а не старое.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let st = Status.load(), st.isFresh,
               st.mode == cfg.mode, st.chargeNow == cfg.chargeNow { break }
            usleep(200_000)
        }
    }
    printStatus()
}

func formatMinutes(_ m: Int) -> String {
    m >= 60 ? "\(m / 60) ч \(m % 60) мин" : "\(m) мин"
}

func printStatus() {
    guard let st = Status.load() else {
        fail("служба BatLimit не установлена.\n"
            + "Запусти приложение BatLimit и выбери «Установить службу…» в меню.")
    }

    let pct = "\(st.percentage)%"
    let charge: String
    if st.settling == true {
        // Контроллер заряда перечитывает SMC-ключ раз в ~45–50 с.
        charge = yellow("переключается…")
    } else if st.isCharging {
        charge = green("заряжается")
    } else {
        charge = st.inhibited ? yellow("зарядка заблокирована") : dim("не заряжается")
    }
    let power = st.isPluggedIn ? "от сети" : "от батареи"

    print("\(bold(pct))  ·  \(power)  ·  \(charge)")
    print("режим: \(bold(st.mode.humanReadable))   коридор: \(st.low)–\(st.high)%")
    print(dim(st.phase))

    if let m = st.minutesRemaining {
        print(dim(st.isCharging ? "до полного заряда: \(formatMinutes(m))"
                                : "работы осталось: \(formatMinutes(m))"))
    }
    if let cycles = st.cycleCount {
        print(dim("циклов зарядки: \(cycles)"))
    }
    if let energy = st.energyModes, !energy.isEmpty {
        let parts = PowerSourceKey.allCases.compactMap { source in
            energy[source].map { "\(source.humanReadable) — \($0.humanReadable)" }
        }
        print(dim("режим энергии: " + parts.joined(separator: ", ")))
    }
    if st.settling == true {
        print(dim("команда отправлена — контроллер применит её в течение ~минуты"))
    }
    if st.systemLimitActive && st.percentage < st.high {
        print(yellow("Зарядку держит системный лимит macOS — верхний порог "
            + "\(st.high)% недостижим, пока лимит включён "
            + "(Настройки → Аккумулятор)."))
    }
    if let err = st.error {
        print(red("ошибка демона: \(err)"))
    }
    if !st.isFresh {
        print(red("демон не обновлял статус \(Int(Date().timeIntervalSince(st.updatedAt))) с — возможно, он не запущен"))
    }
}

func parsePercent(_ s: String, _ name: String) -> Int {
    guard let v = Int(s.replacingOccurrences(of: "%", with: "")), (5...100).contains(v) else {
        fail("\(name) должен быть числом от 5 до 100, получено «\(s)»")
    }
    return v
}

// MARK: - Разбор аргументов

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "status":
    printStatus()

case "hold":
    update { $0.mode = .hold; $0.chargeNow = false }

case "charge":
    // Верхний порог уже достигнут — команда была бы пустой: демон погасил бы
    // флаг тем же тиком, а пользователь решил бы, что плагин сломан.
    let limits = Config.load()
    if let st = Status.load(), st.isFresh, st.percentage >= limits.high {
        fail("заряд уже \(st.percentage)%, верхний порог \(limits.high)% — заряжать нечего.\n"
            + "Подними порог: batlimit limits \(limits.low) <верх>")
    }
    update { $0.chargeNow = true }

case "off":
    update { $0.mode = .off; $0.chargeNow = false }

case "auto":
    update {
        $0.mode = .auto
        $0.chargeNow = false
        if args.count >= 3 {
            $0.low = parsePercent(args[1], "нижний порог")
            $0.high = parsePercent(args[2], "верхний порог")
        } else if args.count == 2 {
            $0.low = parsePercent(args[1], "нижний порог")
        }
    }

case "limits":
    guard args.count == 3 else { fail("нужно два значения: batlimit limits 30 80") }
    update({
        $0.low = parsePercent(args[1], "нижний порог")
        $0.high = parsePercent(args[2], "верхний порог")
    }, waitForChange: false)

case "check":
    let check = SystemCheck.run()
    print(check.summary)
    if !check.isSupported { exit(1) }

case "smc":
    guard args.count == 2 else { fail("нужен ключ: batlimit smc CHTE") }
    do {
        let controller = try ChargingController()
        let (bytes, type) = try controller.rawRead(args[1])
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("\(args[1])  type=\(type)  size=\(bytes.count)  [\(hex)]")
        print(dim("активный набор ключей: \(controller.api.rawValue)"))
    } catch {
        fail("\(error)")
    }

case "help", "-h", "--help":
    usage()

case let unknown:
    FileHandle.standardError.write((red("Неизвестная команда «\(unknown)»\n\n")).data(using: .utf8)!)
    usage()
    exit(1)
}
