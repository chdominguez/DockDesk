// SPDX-License-Identifier: LGPL-2.1-or-later
// Checksums used by the Panamera update (fwupd fu-synaptics-mst-common.c, fu-sum.c).
// The fwupd tables are the MSB-first polynomials 0xD5 (CRC-8) and 0x8005 (CRC-16), init 0,
// no reflection, no final xor; they are regenerated here from the polynomials.

import CryptoKit
import Foundation

public enum Checksum {
    private static let crc8Table: [UInt8] = (0..<256).map { i -> UInt8 in
        var c = UInt8(i)
        for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0xD5 : c << 1 }
        return c
    }
    private static let crc16Table: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
        return c
    }

    /// fu_synaptics_mst_calculate_crc8(0, ...): used for byte 15 of a bank tag.
    public static func crc8<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        var r: UInt8 = 0
        for b in bytes { r = crc8Table[Int(b ^ r)] }
        return r
    }

    /// fu_synaptics_mst_calculate_crc16(0, ...): what RC 0x17 (CAL_EEPROM_CHECK_CRC16) is compared to.
    public static func crc16<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var r: UInt16 = 0
        for b in bytes { r = crc16Table[Int(b ^ UInt8(r >> 8))] ^ (r << 8) }
        return r
    }

    /// fu_sum32: arithmetic sum of bytes; what RC 0x11 (CAL_EEPROM_CHECKSUM) returns.
    public static func sum32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var s: UInt32 = 0
        for b in bytes { s &+= UInt32(b) }
        return s
    }

    public static func sha256<D: DataProtocol>(_ data: D) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(_ bytes: [UInt8]) -> String { sha256(Data(bytes)) }
}
