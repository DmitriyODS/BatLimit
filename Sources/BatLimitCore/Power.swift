import Foundation

/// Сколько ватт ноутбук потребляет прямо сейчас.
///
/// Основной источник — SMC-ключ `PSTR` («system total power»): та же величина,
/// что показывает `powermetrics`, но читается без root и обновляется примерно
/// раз в секунду. Соединение с SMC держим открытым: панель опрашивает счётчик
/// ежесекундно, и переоткрывать user-client на каждый замер незачем.
///
/// Где ключа нет, остаётся оценка по батарее. Она грубее — газоанализатор
/// обновляет показания раз в десятки секунд, — но лучше прочерка.
public final class PowerMeter {
    private let smc: SMC?
    /// Ключа `PSTR` нет на части машин. Узнаём это один раз и больше не
    /// дёргаем SMC впустую на каждом замере.
    private var smcUsable = true

    public init() {
        smc = try? SMC()
        smcUsable = smc != nil
    }

    /// Текущее потребление в ваттах или nil, если измерить нечем.
    public func read() -> Double? {
        if let watts = smcWatts() { return watts }
        return batteryWatts()
    }

    // MARK: - Источники

    private func smcWatts() -> Double? {
        guard smcUsable, let smc else { return nil }
        guard let bytes = try? smc.read("PSTR"), bytes.count == 4 else {
            smcUsable = false
            return nil
        }
        // Числа типа `flt ` лежат little-endian, в отличие от остальных
        // значений SMC.
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let watts = Double(Float(bitPattern: bits))
        guard watts.isFinite, watts > 0, watts < 1000 else { return nil }
        return watts
    }

    private func batteryWatts() -> Double? {
        guard let props = Battery.properties() else { return nil }

        // Газоанализатор сам считает потребление системы — на Apple Silicon
        // это поле есть и заполнено даже при работе от сети.
        if let data = props["BatteryData"] as? [String: Any],
           let power = data["SystemPower"] as? Double, power > 0 {
            return power
        }

        // Иначе: разряд батареи — это и есть потребление. При зарядке ток
        // положительный и о расходе системы ничего не говорит.
        guard let milliAmps = props["Amperage"] as? Int, milliAmps < 0,
              let milliVolts = props["Voltage"] as? Int, milliVolts > 0 else { return nil }
        return Double(-milliAmps) * Double(milliVolts) / 1_000_000
    }
}
