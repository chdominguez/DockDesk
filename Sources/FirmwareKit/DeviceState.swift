// SPDX-License-Identifier: LGPL-2.1-or-later
// Read-only device inspection (identity, active bank, tags, chip checksums).

import Foundation

public struct HubIdentity: Equatable {
    public let oui: [UInt8]
    public let deviceId: [UInt8]      // 6 bytes at DPCD 0x503, "SYNA" + chip id
    public let chipId: UInt16
    public let firmware: [UInt8]      // DPCD 0x50A..0x50C
    public let rcCapable: Bool

    public var firmwareString: String { formatVersion(firmware) }
}

/// Everything the planner needs to know about the live device. Produced only by reads.
public struct DeviceSnapshot: Equatable {
    public let identity: HubIdentity
    public let configSignature: [UInt8]   // RAM 0x1700, 4 bytes
    public let boardId: UInt16            // RAM 0x170E, u16 BE
    public let bootStatus: UInt32         // RAM 0x20010C, u32 LE
    public let tags: [BankTag]            // flash bank + 0x1FFF0
    public let bankSum32: [UInt32]        // RC 0x11 over each whole bank
    public let esmSum32: UInt32           // RC 0x11 over 0x40000..0x7FFFF
    public let quadRegister: [UInt8]      // RAM 0x200FC0, 4 bytes
    public let hdcpRegister: [UInt8]      // RAM 0x200F90, 4 bytes

    /// fwupd: `if ((buf[0] & BIT(7)) || (buf[0] & BIT(30))) active_bank = 1 else 0`.
    public var activeBank: Int { DeviceSnapshot.activeBank(fromBootStatus: bootStatus) }
    public static func activeBank(fromBootStatus s: UInt32) -> Int { (s & (1 << 7)) != 0 || (s & (1 << 30)) != 0 ? 1 : 0 }
    public var inactiveBank: Int { 1 - activeBank }
}

public enum DeviceReader {
    /// DPCD-only identity, no RC session needed.
    public static func identity(_ t: HubTransport) throws -> HubIdentity {
        let b = try t.dpcdRead(Panamera.dpcdBranchOUI, count: 13)
        let cap = try t.dpcdRead(Panamera.dpcdRCCapability, count: 1)
        return HubIdentity(oui: Array(b[0..<3]), deviceId: Array(b[3..<9]),
                           chipId: UInt16(b[7]) << 8 | UInt16(b[8]),
                           firmware: Array(b[10..<13]), rcCapable: cap[0] & 0x04 != 0)
    }

    /// Full read-only snapshot. Opens and closes its own RC session.
    public static func snapshot(_ t: HubTransport) throws -> DeviceSnapshot {
        let id = try identity(t)
        guard id.rcCapable else { throw HubTransportError.notSupported("hub does not advertise RC (DPCD 0x4B0 bit 2)") }
        try t.rcEnable()
        defer { try? t.rcDisable() }
        let cfg = try t.rcReadMemory(Panamera.ramConfig, count: 4)
        let bid = try t.rcReadMemory(Panamera.ramBoardId, count: 2)
        let status = try t.readU32LE(memory: Panamera.regBootStatus)
        let tags = try (0..<2).map { BankTag(try t.rcReadFlash(UInt32(Panamera.bankBase($0) + Panamera.tagOffset), count: Panamera.tagSize)) }
        let sums = try (0..<2).map { try t.rcFlashSum32(UInt32(Panamera.bankBase($0)), length: UInt32(Panamera.bankSize)) }
        let esm = try t.rcFlashSum32(UInt32(Panamera.esmOffset), length: UInt32(Panamera.esmSize))
        let quad = try t.rcReadMemory(Panamera.regQuadDisable, count: 4)
        let hdcp = try t.rcReadMemory(Panamera.regHDCP22Disable, count: 4)
        return DeviceSnapshot(identity: id, configSignature: cfg, boardId: UInt16(bid[0]) << 8 | UInt16(bid[1]),
                              bootStatus: status, tags: tags, bankSum32: sums, esmSum32: esm,
                              quadRegister: quad, hdcpRegister: hdcp)
    }
}
