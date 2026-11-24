// SPDX-License-Identifier: LGPL-2.1-or-later
// What to put into the inactive bank.

import Foundation

public struct FlashTarget {
    public let description: String
    public let version: [UInt8]
    public let esmSum32: UInt32
    public let boardId: UInt16
    /// True when the tag for the target bank is not byte-identical to one Dell shipped.
    public let synthesizedTag: Bool
    /// Body (0..<0x1FFF0) common to both banks.
    let body: [UInt8]
    /// Exact tag per bank index.
    let tags: [BankTag]

    /// The 128 KiB that will end up in `bank`.
    public func content(forBank bank: Int) -> [UInt8] { body + tags[bank].bytes }
    public var bodyInfo: BankInfo { BankInfo.inspect(bank: 0, ArraySlice(content(forBank: 0))) }

    /// A Dell image from the built-in table. Writes the image's own half for the target bank, exactly
    /// what dell-dock writes (fu_dell_dock_mst_write_flash_bank writes `data + bank_start`).
    public static func dell(_ image: VMMImage, requireFlashTarget: Bool = true) throws -> FlashTarget {
        if requireFlashTarget && !image.package.flashTarget {
            throw ImageError.notAFlashTarget("\(image.package.fileName) (hub \(image.package.hubVersionString))")
        }
        let a = image.analysis
        return FlashTarget(description: "Dell \(image.package.fileName) hub \(image.package.hubVersionString)",
                           version: image.version, esmSum32: a.esmSum32, boardId: a.banks[0].boardId,
                           synthesizedTag: false, body: Array(image.body), tags: a.banks.map { $0.tag })
    }

    /// Offset of the display-mode byte inside a bank (config block 0x100 + 0x40; RAM 0x1740 mirrors it)
    /// and of the config block's checksum byte.
    public static let modeByteOffset = 0x140
    public static let configChecksumOffset = 0x1FF

    /// The Dell 05.07.04 image with one setting changed: the hub boots in split mode (ViewXpand)
    /// instead of mirror, so it offers the wide display without a monitor replug.
    /// Exactly two bytes differ from Dell's image: the mode byte's low nibble (3 -> 2) and the config
    /// checksum byte (+1). The config block still sums to 0 and the bank's byte sum is unchanged.
    /// Dell's tags are kept (assumption A4: the boot ROM does not check tag bytes against content).
    public static func splitDefault(_ image: VMMImage) throws -> FlashTarget {
        guard image.package == KnownFirmware.viewXpandPackage else {
            throw ImageError.notAFlashTarget("split default is only defined for hub \(KnownFirmware.viewXpandPackage.hubVersionString)")
        }
        let dell = try dell(image)
        var body = dell.body
        let mode = body[modeByteOffset], sum = body[configChecksumOffset]
        guard mode & 0x0F == 0x03, sum != 0xFF else {
            throw ImageError.inconsistent(String(format: "unexpected config: mode byte %02x, checksum byte %02x", mode, sum))
        }
        body[modeByteOffset] = mode - 1
        body[configChecksumOffset] = sum + 1
        let t = FlashTarget(description: dell.description + ", boot default changed to split (not a Dell image)",
                            version: dell.version, esmSum32: dell.esmSum32, boardId: dell.boardId,
                            synthesizedTag: false, body: body, tags: dell.tags)
        guard t.bodyInfo.looksLikeWD19Firmware, t.bodyInfo.sum32 == dell.bodyInfo.sum32 else {
            throw ImageError.inconsistent("patched image failed its structural checks")
        }
        return t
    }

    /// Go back to the firmware that was running when `backup` was taken.
    /// If that firmware is byte-identical to a known Dell image, that image is used (Dell's own tags).
    /// Otherwise the backup's body is used with its tag re-targeted to the new bank, which is refused
    /// unless `allowSynthesizedTag` (the boot ROM's acceptance of such a tag is unverified, assumption A4).
    public static func restore(from backup: VerifiedBackup, knownImages: [VMMImage], allowSynthesizedTag: Bool = false) throws -> FlashTarget {
        let rb = backup.runningBank
        let info = backup.analysis.banks[rb]
        guard info.tagValid else { throw ImageError.inconsistent("backup's running bank \(rb) has no valid tag") }
        guard info.looksLikeWD19Firmware, info.tagSectorPaddingOnly else {
            throw ImageError.notWD19("backup's running bank does not look like WD19 firmware")
        }
        if let img = knownImages.first(where: { $0.analysis.banks[0].bodySHA256 == info.bodySHA256 }) {
            let t = try dell(img, requireFlashTarget: false)
            return FlashTarget(description: "restore of backup \(backup.url.lastPathComponent) == " + t.description,
                               version: t.version, esmSum32: t.esmSum32, boardId: t.boardId,
                               synthesizedTag: false, body: t.body, tags: t.tags)
        }
        guard allowSynthesizedTag else {
            throw ImageError.unknownImage(sha256: "backup body \(info.bodySHA256) matches no known Dell image; pass allowSynthesizedTag to restore it anyway")
        }
        let body = Array(backup.bank(rb).prefix(Panamera.tagOffset))
        return FlashTarget(description: "restore of backup \(backup.url.lastPathComponent) (synthesized tag)",
                           version: info.version, esmSum32: backup.analysis.esmSum32, boardId: info.boardId,
                           synthesizedTag: true, body: body,
                           tags: (0..<2).map { BankTag.retargeted(info.tag, toBank: $0) })
    }
}
