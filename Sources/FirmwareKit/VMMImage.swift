// SPDX-License-Identifier: LGPL-2.1-or-later
// Parsing of VMM5331 flash images (Dell vmm5331.bin) and of full flash dumps/backups.

import Foundation

/// The 16-byte tag at bank + 0x1FFF0. Format (fwupd update_panamera_set_new_valid_cb):
/// [0]=bank, [1]=month, [2]=day, [3]=year-2000, [4..5]=checksum hi/lo (Dell images: always 4A 51),
/// [6..14]=0, [15]=CRC-8 of bytes 0..14.
public struct BankTag: Equatable, CustomStringConvertible {
    public let bytes: [UInt8]
    public init(_ bytes: [UInt8]) { precondition(bytes.count == Panamera.tagSize); self.bytes = bytes }

    public var isErased: Bool { bytes.allSatisfy { $0 == 0xFF } }
    public var crcValid: Bool { Checksum.crc8(bytes[0..<15]) == bytes[15] }
    /// What we assume the boot ROM accepts (assumption A3 in docs/flasher.md).
    public func isValid(forBank bank: Int) -> Bool { !isErased && crcValid && Int(bytes[0]) == bank }
    public var hasDellMarker: Bool { Array(bytes[4...5]) == Panamera.dellTagMarker && bytes[6...14].allSatisfy { $0 == 0 } }
    public var description: String { hex(bytes) }

    /// Tag for `bank` with the date/marker fields of `template` and a fresh CRC-8.
    public static func retargeted(_ template: BankTag, toBank bank: Int) -> BankTag {
        var b = template.bytes
        b[0] = UInt8(bank)
        b[15] = Checksum.crc8(b[0..<15])
        return BankTag(b)
    }
}

/// Structural facts about one 128 KiB bank.
public struct BankInfo: Equatable {
    public let index: Int
    public let tag: BankTag
    public let edidHeaderOK: Bool
    public let configSignatureOK: Bool
    public let configChecksumOK: Bool
    public let boardId: UInt16
    public let codeEnd: Int            // u32 BE at 0x400 + 0x410
    public let version: [UInt8]        // bytes at 0x18400
    public let bodySHA256: String      // bytes 0..<0x1FFF0
    public let sum32: UInt32           // whole bank
    public let tagSectorPaddingOnly: Bool  // 0x1F000..<0x1FFF0 holds only 00/FF bytes (padding or erased)

    public var tagValid: Bool { tag.isValid(forBank: index) }
    public var looksLikeWD19Firmware: Bool {
        edidHeaderOK && configSignatureOK && configChecksumOK && boardId == Panamera.dellWD19BoardId
            && codeEnd <= Panamera.maxCodeSize && codeEnd <= Panamera.tagSectorOffset
    }

    public static func inspect(bank: Int, _ b: ArraySlice<UInt8>) -> BankInfo {
        precondition(b.count == Panamera.bankSize)
        let o = b.startIndex
        func at(_ i: Int) -> UInt8 { b[o + i] }
        let cfg = b[(o + Panamera.configOffset)..<(o + Panamera.configOffset + Panamera.configSize)]
        let size = (Int(at(0x400)) << 24 | Int(at(0x401)) << 16 | Int(at(0x402)) << 8 | Int(at(0x403))) + Panamera.codeSizeBias
        let pad = b[(o + Panamera.tagSectorOffset)..<(o + Panamera.tagOffset)]
        return BankInfo(
            index: bank,
            tag: BankTag(Array(b[(o + Panamera.tagOffset)..<(o + Panamera.bankSize)])),
            edidHeaderOK: Array(b[o..<(o + 8)]) == Panamera.edidHeader,
            configSignatureOK: Array(cfg.prefix(4)) == Panamera.configSignature,
            configChecksumOK: Checksum.sum32(cfg) & 0xFF == 0,
            boardId: UInt16(at(Panamera.boardIdOffset)) << 8 | UInt16(at(Panamera.boardIdOffset + 1)),
            codeEnd: size,
            version: [at(Panamera.versionOffset), at(Panamera.versionOffset + 1), at(Panamera.versionOffset + 2)],
            bodySHA256: Checksum.sha256(Data(b[o..<(o + Panamera.tagOffset)])),
            sum32: Checksum.sum32(b),
            tagSectorPaddingOnly: pad.allSatisfy { $0 == 0x00 || $0 == 0xFF })
    }
}

/// Analysis of a full 512 KiB flash content (device dump, backup, or Dell image).
public struct FlashAnalysis: Equatable {
    public let banks: [BankInfo]
    public let esmSum32: UInt32
    public let sha256: String

    public init(_ flash: [UInt8]) throws {
        guard flash.count == Panamera.flashSize else { throw ImageError.wrongSize(flash.count) }
        banks = (0..<2).map { BankInfo.inspect(bank: $0, flash[Panamera.bankBase($0)..<(Panamera.bankBase($0) + Panamera.bankSize)]) }
        esmSum32 = Checksum.sum32(flash[Panamera.esmOffset..<Panamera.flashSize])
        sha256 = Checksum.sha256(flash)
    }

    /// Banks whose tag we believe the boot ROM accepts.
    public var validBanks: [Int] { banks.filter { $0.tagValid }.map { $0.index } }
}

public enum ImageError: Error, CustomStringConvertible, Equatable {
    case wrongSize(Int)
    case unknownImage(sha256: String)
    case notWD19(String)
    case inconsistent(String)
    case notAFlashTarget(String)

    public var description: String {
        switch self {
        case .wrongSize(let n): return "image is \(n) bytes, expected \(Panamera.flashSize)"
        case .unknownImage(let s): return "image sha256 \(s) is not in the table of known Dell WD19 hub images"
        case .notWD19(let s): return "does not look like a Dell WD19 VMM5331 image: \(s)"
        case .inconsistent(let s): return "image inconsistent: \(s)"
        case .notAFlashTarget(let s): return "image is known but not allowed as a flash target: \(s)"
        }
    }
}

/// A verified Dell `vmm5331.bin` (512 KiB: bank 0 half, bank 1 half, ESM).
public struct VMMImage {
    public let bytes: [UInt8]
    public let package: KnownPackage
    public let analysis: FlashAnalysis

    public var version: [UInt8] { package.hubVersion }

    /// Structural checks only (used by tests and diagnostics). Returns the problems found.
    public static func structuralProblems(_ data: [UInt8]) -> [String] {
        guard let a = try? FlashAnalysis(data) else { return ["size \(data.count) != \(Panamera.flashSize)"] }
        var p: [String] = []
        for b in a.banks {
            let n = "bank \(b.index)"
            if !b.edidHeaderOK { p.append("\(n): no EDID header at +0") }
            if !b.configSignatureOK { p.append("\(n): config signature != 20 00 83 83") }
            if !b.configChecksumOK { p.append("\(n): config block checksum (0x100..0x1FF) != 0") }
            if b.boardId != Panamera.dellWD19BoardId { p.append(String(format: "\(n): board id 0x%04x != 0x0103", b.boardId)) }
            if b.codeEnd > Panamera.maxCodeSize || b.codeEnd > Panamera.tagSectorOffset { p.append("\(n): code end \(h(b.codeEnd)) too large") }
            if !b.tagSectorPaddingOnly { p.append("\(n): last 4 KiB sector contains data besides the tag") }
            if !b.tagValid { p.append("\(n): tag \(b.tag) invalid for bank \(b.index)") }
            if !b.tag.hasDellMarker { p.append("\(n): tag lacks the 4A 51 marker seen in every Dell image") }
        }
        if a.banks[0].version != a.banks[1].version { p.append("bank versions differ") }
        if data[0..<Panamera.tagOffset] != data[Panamera.bankSize..<(Panamera.bankSize + Panamera.tagOffset)] {
            p.append("bank halves differ outside the tag")
        }
        if Array(data[Panamera.tagOffset + 1..<Panamera.tagOffset + 15]) != Array(data[Panamera.bankSize + Panamera.tagOffset + 1..<Panamera.bankSize + Panamera.tagOffset + 15]) {
            p.append("tags differ in more than bank byte / crc")
        }
        return p
    }

    /// Strict parse: must be byte-identical to a known Dell WD19 hub image and structurally sound.
    public static func parse(_ data: [UInt8]) throws -> VMMImage {
        guard data.count == Panamera.flashSize else { throw ImageError.wrongSize(data.count) }
        let sha = Checksum.sha256(data)
        guard let pkg = KnownFirmware.package(hubImageSHA256: sha) else { throw ImageError.unknownImage(sha256: sha) }
        let problems = structuralProblems(data)
        guard problems.isEmpty else { throw ImageError.notWD19(problems.joined(separator: "; ")) }
        let a = try FlashAnalysis(data)
        guard a.banks[0].version == pkg.hubVersion else {
            throw ImageError.inconsistent("version at 0x18400 is \(formatVersion(a.banks[0].version)), table says \(pkg.hubVersionString)")
        }
        guard a.esmSum32 == pkg.esmSum32 else { throw ImageError.inconsistent("ESM sum \(h32(a.esmSum32)) != table \(h32(pkg.esmSum32))") }
        return VMMImage(bytes: data, package: pkg, analysis: a)
    }

    public static func load(_ url: URL) throws -> VMMImage { try parse([UInt8](try Data(contentsOf: url))) }

    /// Exactly the 128 KiB Dell wrote for `bank` (bank half of the file, including Dell's own tag for that bank).
    public func bankContent(for bank: Int) -> [UInt8] {
        Array(bytes[Panamera.bankBase(bank)..<(Panamera.bankBase(bank) + Panamera.bankSize)])
    }
    public var body: ArraySlice<UInt8> { bytes[0..<Panamera.tagOffset] }
    public var esm: ArraySlice<UInt8> { bytes[Panamera.esmOffset..<Panamera.flashSize] }
}
