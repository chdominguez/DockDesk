// SPDX-License-Identifier: LGPL-2.1-or-later
// Transport abstraction over the Synaptics RC protocol (DPCD 0x4B0..0x4DF, see docs/flasher.md).

import Foundation

/// The primitives the firmware module needs from the hub.
///
/// Implementations: `SimulatedHub` (tests), `CDockTransport` (read-only part wired to CDock today;
/// the mutating part needs the `td_fw_*` additions proposed in docs/flasher.md).
///
/// The three mutating primitives take a `WriteAuthorization`. That token can only be created inside
/// FlashExecutor.swift (its initialiser is `fileprivate`), and only when the caller passed
/// `allowWrites: true` and all guards passed. No other code in this module can erase or program flash
/// or write hub memory.
public protocol HubTransport: AnyObject {
    /// Raw DPCD read (identity registers 0x500.., RC capability 0x4B0).
    func dpcdRead(_ address: UInt32, count: Int) throws -> [UInt8]

    /// RC session: ENABLE_RC (0x01, "PRIUS") / DISABLE_RC (0x02).
    func rcEnable() throws
    func rcDisable() throws

    /// READ_FROM_MEMORY (0x31) and READ_FROM_EEPROM (0x30). Implementations chunk to 32 bytes.
    func rcReadMemory(_ address: UInt32, count: Int) throws -> [UInt8]
    func rcReadFlash(_ address: UInt32, count: Int) throws -> [UInt8]

    /// CAL_EEPROM_CHECKSUM (0x11): offset/length in RC_OFFSET/RC_LEN, 4 bytes LE result in RC_DATA.
    /// The chip sums the bytes itself; nothing is modified.
    func rcFlashSum32(_ address: UInt32, length: UInt32) throws -> UInt32
    /// CAL_EEPROM_CHECK_CRC16 (0x17), same calling convention. Optional (see FlashOptions).
    func rcFlashCRC16(_ address: UInt32, length: UInt32) throws -> UInt32

    /// WRITE_TO_MEMORY (0x21), <= 32 bytes.
    func rcWriteMemory(_ address: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws
    /// FLASH_ERASE (0x14) with the 2-byte little-endian erase code in RC_DATA (fwupd synaptics-mst form).
    func rcEraseFlash(code: UInt16, _ auth: WriteAuthorization) throws
    /// WRITE_TO_EEPROM (0x20), <= 32 bytes, must not cross a 32-byte boundary.
    func rcWriteFlash(_ address: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws

    /// Delay hook so the simulator does not actually sleep.
    func sleep(milliseconds: Int)
}

public enum HubTransportError: Error, CustomStringConvertible, Equatable {
    case notConnected
    case rcNotEnabled
    case rcFailed(command: UInt8, code: Int)
    case notSupported(String)
    case outOfRange(String)
    case io(String)

    public var description: String {
        switch self {
        case .notConnected: return "hub not reachable"
        case .rcNotEnabled: return "remote control not enabled"
        case .rcFailed(let c, let code): return String(format: "RC command 0x%02x failed (%d)", c, code)
        case .notSupported(let s): return "not supported by this transport: \(s)"
        case .outOfRange(let s): return "out of range: \(s)"
        case .io(let s): return "I/O error: \(s)"
        }
    }
}

extension HubTransport {
    func readU32LE(memory address: UInt32) throws -> UInt32 {
        let b = try rcReadMemory(address, count: 4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}
