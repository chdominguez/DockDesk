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
