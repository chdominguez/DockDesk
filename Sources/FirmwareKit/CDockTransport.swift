// SPDX-License-Identifier: LGPL-2.1-or-later
// HubTransport backed by CDock. Only the read-only primitives that CDock has today are wired.
// The checksum and mutating primitives throw `.notSupported` until the td_fw_* / td_rc_checksum
// additions proposed in docs/flasher.md exist. This file never opens a device: the caller passes
// a handle it obtained from td_open() and keeps ownership.

import CDock
import Foundation

public final class CDockTransport: HubTransport {
    let dock: OpaquePointer

    public init(dock: OpaquePointer) { self.dock = dock }

    private func ok(_ r: Int32, _ what: String) throws {
        guard r == 0 else { throw HubTransportError.io("\(what) returned \(r)") }
    }

    public func dpcdRead(_ address: UInt32, count: Int) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        try ok(td_dpcd_read(dock, address, &b, UInt32(count)), "td_dpcd_read")
        return b
    }

    /// Set by the caller for a real flashing run; each RC session is then armed for td_fw_* calls.
    public var armForWrites = false

    public func rcEnable() throws {
        try ok(td_rc_enable(dock), "td_rc_enable")
        if armForWrites { try ok(td_fw_arm(dock, TD_FW_ARM_MAGIC), "td_fw_arm") }
    }
    public func rcDisable() throws { try ok(td_rc_disable(dock), "td_rc_disable") }

    public func rcReadMemory(_ address: UInt32, count: Int) throws -> [UInt8] {
        var b = [UInt8](repeating: 0, count: count)
        try ok(td_rc_read_memory(dock, address, &b, UInt32(count)), "td_rc_read_memory")
        return b
    }

    public func rcReadFlash(_ address: UInt32, count: Int) throws -> [UInt8] {
        guard Int(address) + count <= Panamera.flashSize else { throw HubTransportError.outOfRange("flash") }
        var b = [UInt8](repeating: 0, count: count)
        try ok(td_rc_read_flash(dock, address, &b, UInt32(count)), "td_rc_read_flash")
        return b
    }

    public func rcFlashSum32(_ address: UInt32, length: UInt32) throws -> UInt32 {
        var v: UInt32 = 0
        try ok(td_rc_checksum(dock, address, length, &v), "td_rc_checksum")
        return v
    }
    public func rcFlashCRC16(_ address: UInt32, length: UInt32) throws -> UInt32 {
        var v: UInt32 = 0
        try ok(td_rc_crc16(dock, address, length, &v), "td_rc_crc16")
        return v
    }
    public func rcWriteMemory(_ address: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws {
        try ok(td_fw_write_memory(dock, address, bytes, UInt32(bytes.count)), "td_fw_write_memory")
    }
    public func rcEraseFlash(code: UInt16, _ auth: WriteAuthorization) throws {
        try ok(td_fw_erase(dock, code), "td_fw_erase")
    }
    public func rcWriteFlash(_ address: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws {
        try ok(td_fw_write_flash(dock, address, bytes, UInt32(bytes.count)), "td_fw_write_flash")
    }
    public func sleep(milliseconds: Int) { usleep(useconds_t(milliseconds) * 1000) }
}
