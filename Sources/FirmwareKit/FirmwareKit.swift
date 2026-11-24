// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Hub firmware backup, verification and flashing for the Synaptics VMM5331
// ("Panamera") MST hub inside Dell WD19-family docks. See docs/flasher.md.
//
// The constants and the update procedure in this module are derived from fwupd
// (plugins/synaptics-mst/fu-synaptics-mst-device.c and
// plugins/dell-dock/fu-dell-dock-mst.c, tag 2.0.20), which are LGPL-2.1-or-later.

import Foundation

/// Layout and protocol constants for the VMM5331 as used in the Dell WD19.
public enum Panamera {
    // MARK: Flash layout (fwupd: EEPROM_BANK_OFFSET, EEPROM_TAG_OFFSET, EEPROM_ESM_OFFSET)
    public static let flashSize = 0x80000
    public static let bankSize = 0x20000
    public static let tagOffset = 0x1FFF0          // within a bank
    public static let tagSize = 16
    public static let tagSectorOffset = 0x1F000    // last 4 KiB sector of a bank, holds only padding + tag
    public static let esmOffset = 0x40000
    public static let esmSize = 0x40000
    public static let maxCodeSize = 0x1A000        // fwupd PANAMERA_FIRMWARE_SIZE
    public static let codeSizeOffset = 0x400       // u32 BE, code size minus 0x410
    public static let codeSizeBias = 0x410
    public static let versionOffset = 0x18400      // dell-dock DellDockBlob{Major,Minor,Build}Offset
    public static let configOffset = 0x100
    public static let configSize = 0x100           // 0x100..0x1FF, byte sum == 0 mod 256
    public static let configSignature: [UInt8] = [0x20, 0x00, 0x83, 0x83]
    public static let boardIdOffset = 0x10E        // fwupd ADDR_CUSTOMER_ID_TESLA, u16 BE
    public static let edidHeader: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    /// Bytes 4..5 of every tag in every Dell WD19 image we have seen (all 8 distinct images).
    public static let dellTagMarker: [UInt8] = [0x4A, 0x51]

    // MARK: Identity
    public static let chipId: UInt16 = 0x5331
    public static let synapticsOUI: [UInt8] = [0x90, 0xCC, 0x24]
    public static let deviceIdPrefix: [UInt8] = Array("SYNA".utf8)
    /// customer 0x01 (Dell) / board 0x03; dell-dock instance id "MST-panamera-vmm5331-259" (259 == 0x0103).
    public static let dellWD19BoardId: UInt16 = 0x0103

    // MARK: DPCD registers
    public static let dpcdBranchOUI: UInt32 = 0x500     // 3 bytes OUI, 6 bytes device id, hw rev, fw version
    public static let dpcdChipId: UInt32 = 0x507        // u16 BE (last two bytes of the device id string)
    public static let dpcdFirmwareVersion: UInt32 = 0x50A
    public static let dpcdRCCapability: UInt32 = 0x4B0  // bit 2 = remote control supported

    // MARK: Hub memory (RC READ/WRITE_MEMORY address space)
    public static let ramConfig: UInt32 = 0x1700        // copy of the running bank's config block
    public static let ramBoardId: UInt32 = 0x170E       // fwupd ADDR_MEMORY_CUSTOMER_ID
    public static let regBootStatus: UInt32 = 0x20010C  // PANAMERA_MST_CORE_MCU_BOOTLOADER_STS
    public static let regMcuCommand: UInt32 = 0x2000FC  // REG_ESM_DISABLE / restart / dell-dock RC trigger
    public static let regQuadDisable: UInt32 = 0x200FC0
    public static let regHDCP22Disable: UInt32 = 0x200F90
    public static let mcuCommandStopESM: UInt8 = 0x21
    public static let mcuCommandReboot: UInt8 = 0xF5

    // MARK: RC command codes (fu-synaptics-mst.rs FuSynapticsMstUpdcCmd)
    public enum RC: UInt8 {
        case enable = 0x01, disable = 0x02
        case calChecksum = 0x11        // arithmetic byte sum, u32 LE in RC_DATA
        case flashErase = 0x14
        case calCRC16 = 0x17
        case writeFlash = 0x20, writeMemory = 0x21
        case readFlash = 0x30, readMemory = 0x31
    }

    // MARK: Erase codes (fwupd fu_synaptics_mst_device_set_flash_sector_erase: u16 LE of type + index)
    public static let erase4K: UInt16 = 0x1000
    public static let erase64K: UInt16 = 0x3000

    public static func bankBase(_ bank: Int) -> Int { bank * bankSize }
    public static func eraseCode64K(sector: Int) -> UInt16 { erase64K + UInt16(sector) }
    public static func eraseCode4K(sector: Int) -> UInt16 { erase4K + UInt16(sector) }
    /// The two 64 KiB sectors covering `bank`.
    public static func bankEraseCodes(_ bank: Int) -> [UInt16] { [eraseCode64K(sector: bank * 2), eraseCode64K(sector: bank * 2 + 1)] }
    /// The 4 KiB sector holding `bank`'s tag (fwupd: (EEPROM_BANK_OFFSET*bank + EEPROM_BANK_OFFSET - 0x1000) / 0x1000).
    public static func tagSectorEraseCode(_ bank: Int) -> UInt16 { eraseCode4K(sector: (bankBase(bank) + bankSize - 0x1000) / 0x1000) }

    /// Decoded erase command: byte range it clears.
    public static func eraseRange(code: UInt16) -> Range<Int>? {
        let kind = code >> 12, index = Int(code & 0x0FFF)
        let size: Int
        switch kind {
        case 1: size = 0x1000
        case 2: size = 0x8000
        case 3: size = 0x10000
        default: return nil   // includes 0xFFFF (chip erase): never produced by this module
        }
        let start = index * size
        guard start + size <= flashSize else { return nil }
        return start..<(start + size)
    }
}

/// "05.07.04" style formatting. dell-dock prints the version bytes as hex ("%02x.%02x.%02x"), which is
/// how Dell/LVFS name releases (bytes 05 03 10 = "05.03.10"); fwupd synaptics-mst prints them as decimal.
/// The two agree for every 05.07.x release.
public func formatVersion(_ v: [UInt8]) -> String {
    v.map { String(format: "%02x", $0) }.joined(separator: ".")
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func hex(_ bytes: ArraySlice<UInt8>) -> String { hex(Array(bytes)) }
func h32(_ v: UInt32) -> String { String(format: "0x%08x", v) }
func h(_ v: Int) -> String { String(format: "0x%05x", v) }
