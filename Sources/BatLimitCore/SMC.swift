import Foundation
import IOKit

/// Ошибки работы с SMC (System Management Controller).
public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcResult(UInt8)
    case badKey(String)
    case sizeMismatch(key: String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSMC не найден в IORegistry"
        case .openFailed(let kr):
            return String(format: "IOServiceOpen не удался (0x%08x) — нужен root?", UInt32(bitPattern: kr))
        case .callFailed(let kr):
            return String(format: "IOConnectCallStructMethod не удался (0x%08x)", UInt32(bitPattern: kr))
        case .smcResult(let r):
            // 0x84 = ключ не поддерживается, 0x85 = отказ в доступе
            return String(format: "SMC вернул код 0x%02x", r)
        case .badKey(let k):
            return "Некорректный SMC-ключ «\(k)» (нужно ровно 4 ASCII-символа)"
        case .sizeMismatch(let key, let expected, let got):
            return "Ключ \(key) ожидает \(expected) байт, передано \(got)"
        }
    }
}

/// Тонкая обёртка над user-client'ом AppleSMC.
///
/// Разметка `SMCKeyData_t` (80 байт) воспроизведена вручную по смещениям,
/// чтобы не зависеть от того, как Swift разложит вложенные структуры.
public final class SMC {
    // Смещения полей внутри SMCKeyData_t.
    private static let structSize = 80
    private static let offKey = 0            // UInt32, FourCC
    private static let offDataSize = 28      // UInt32  (keyInfo.dataSize)
    private static let offDataType = 32      // UInt32  (keyInfo.dataType, FourCC)
    private static let offResult = 40        // UInt8
    private static let offData8 = 42         // UInt8   (селектор операции)
    private static let offData32 = 44        // UInt32  (индекс для GetKeyFromIndex)
    private static let offBytes = 48         // 32 байта полезной нагрузки

    // Селекторы user-client'а и операций.
    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let opReadKey: UInt8 = 5
    private static let opWriteKey: UInt8 = 6
    private static let opGetKeyInfo: UInt8 = 9
    private static let opGetKeyFromIndex: UInt8 = 8

    private var connection: io_connect_t = 0

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: - Публичный API

    public struct KeyInfo {
        public let size: Int
        public let type: String
    }

    public func keyInfo(_ key: String) throws -> KeyInfo {
        var input = try makeInput(key)
        input[SMC.offData8] = SMC.opGetKeyInfo
        let out = try call(input)
        return KeyInfo(size: Int(SMC.get32(out, SMC.offDataSize)),
                       type: SMC.fourCCString(SMC.get32(out, SMC.offDataType)))
    }

    /// Читает значение ключа. Размер берётся из keyInfo.
    public func read(_ key: String) throws -> [UInt8] {
        let info = try keyInfo(key)
        var input = try makeInput(key)
        SMC.put32(&input, SMC.offDataSize, UInt32(info.size))
        input[SMC.offData8] = SMC.opReadKey
        let out = try call(input)
        let n = min(info.size, 32)
        return Array(out[SMC.offBytes ..< (SMC.offBytes + n)])
    }

    /// Записывает значение ключа. Требует root.
    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == info.size else {
            throw SMCError.sizeMismatch(key: key, expected: info.size, got: bytes.count)
        }
        var input = try makeInput(key)
        SMC.put32(&input, SMC.offDataSize, UInt32(info.size))
        input[SMC.offData8] = SMC.opWriteKey
        for (i, b) in bytes.enumerated() where i < 32 {
            input[SMC.offBytes + i] = b
        }
        _ = try call(input)
    }

    /// Сколько всего ключей знает SMC (значение ключа `#KEY`).
    public func keyCount() throws -> Int {
        let b = try read("#KEY")
        guard b.count == 4 else { return 0 }
        // Числовые значения SMC хранятся big-endian.
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    /// Имя ключа по его порядковому номеру — для полного перечисления.
    public func key(at index: Int) throws -> String {
        var input = [UInt8](repeating: 0, count: SMC.structSize)
        SMC.put32(&input, SMC.offData32, UInt32(index))
        input[SMC.offData8] = SMC.opGetKeyFromIndex
        let out = try call(input)
        return SMC.fourCCString(SMC.get32(out, SMC.offKey))
    }

    /// Существует ли ключ на этой машине.
    public func exists(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    // MARK: - Внутреннее

    private func makeInput(_ key: String) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: SMC.structSize)
        SMC.put32(&buf, SMC.offKey, try SMC.fourCC(key))
        return buf
    }

    private func call(_ input: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: SMC.structSize)
        var outSize = SMC.structSize

        let kr: kern_return_t = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(connection,
                                          SMC.kSMCHandleYPCEvent,
                                          inPtr.baseAddress!, SMC.structSize,
                                          outPtr.baseAddress!, &outSize)
            }
        }
        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr) }
        let result = output[SMC.offResult]
        guard result == 0 else { throw SMCError.smcResult(result) }
        return output
    }

    // MARK: - Хелперы

    public static func fourCC(_ s: String) throws -> UInt32 {
        let b = Array(s.utf8)
        guard b.count == 4 else { throw SMCError.badKey(s) }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    public static func fourCCString(_ v: UInt32) -> String {
        let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: chars.filter { $0 != 0 }, encoding: .ascii) ?? ""
    }

    private static func put32(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
        buf[off]     = UInt8(v & 0xff)
        buf[off + 1] = UInt8((v >> 8) & 0xff)
        buf[off + 2] = UInt8((v >> 16) & 0xff)
        buf[off + 3] = UInt8((v >> 24) & 0xff)
    }

    private static func get32(_ buf: [UInt8], _ off: Int) -> UInt32 {
        UInt32(buf[off]) | (UInt32(buf[off + 1]) << 8)
            | (UInt32(buf[off + 2]) << 16) | (UInt32(buf[off + 3]) << 24)
    }
}
