import Foundation
import IOKit

/// Raw IOKit access to the AppleSMC user client.
/// Struct layout and selectors follow the well-known SMCKit/smcFanControl
/// lineage (also used by AlDente): a single 80-byte param struct passed to
/// selector kSMCHandleYPCEvent.
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMCKernel {
    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKey: UInt8 = 5
    private static let kSMCWriteKey: UInt8 = 6
    private static let kSMCGetKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]
    private let lock = NSLock()

    var isOpen: Bool { connection != 0 }

    func open() -> Bool {
        guard connection == 0 else { return true }
        precondition(MemoryLayout<SMCParamStruct>.stride == 80,
                     "SMCParamStruct must be exactly 80 bytes")
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    private static func fourCharCode(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection,
                                           Self.kSMCHandleYPCEvent,
                                           &input,
                                           MemoryLayout<SMCParamStruct>.stride,
                                           &output,
                                           &outputSize)
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ code: UInt32) -> SMCKeyInfoData? {
        if let cached = keyInfoCache[code] { return cached }
        var input = SMCParamStruct()
        input.key = code
        input.data8 = Self.kSMCGetKeyInfo
        guard let output = call(&input) else { return nil }
        keyInfoCache[code] = output.keyInfo
        return output.keyInfo
    }

    /// Read a key's raw bytes, or nil if the key doesn't exist / read failed.
    func read(_ key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard isOpen, let code = Self.fourCharCode(key),
              let info = keyInfo(code), info.dataSize > 0, info.dataSize <= 32 else {
            return nil
        }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.kSMCReadKey
        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { raw in
            Data(raw.prefix(Int(info.dataSize)))
        }
    }

    /// Write raw bytes to a key. Returns false if the key doesn't exist or
    /// the payload size doesn't match the key's declared size.
    func write(_ key: String, _ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isOpen, let code = Self.fourCharCode(key),
              let info = keyInfo(code), info.dataSize == UInt32(data.count),
              data.count <= 32 else {
            return false
        }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Self.kSMCWriteKey
        _ = withUnsafeMutableBytes(of: &input.bytes) { raw in
            data.copyBytes(to: raw.bindMemory(to: UInt8.self))
        }
        return call(&input) != nil
    }
}
