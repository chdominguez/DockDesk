// SPDX-License-Identifier: LGPL-2.1-or-later
// Built-in table of Dell dock packages whose VMM5331 image has been inspected offline.

import Foundation

public struct KnownPackage: Equatable {
    public let fileName: String
    public let cabSHA256: String
    public let hubImageSHA256: String
    /// Raw bytes as stored at 0x18400 / DPCD 0x50A; Dell and LVFS print them as hex ("05.03.10").
    public let hubVersion: [UInt8]
    /// Byte sum of the ESM region (0x40000..0x7FFFF) of the image.
    public let esmSum32: UInt32
    /// Allowed as a flash target. Only 05.07.x images, which share the ESM region of the dumped dock.
    public let flashTarget: Bool
    public let url: String
    /// True only for the URL that was given to us and checked; the others follow the same LVFS pattern.
    public let urlVerified: Bool

    public var hubVersionString: String { formatVersion(hubVersion) }
}

public enum KnownFirmware {
    static let esm05_06: UInt32 = 0x01E4_639E
    static let esm05_04: UInt32 = 0x01C9_7260

    private static func lvfs(_ sha: String, _ name: String) -> String { "https://fwupd.org/downloads/\(sha)-\(name)" }

    public static let packages: [KnownPackage] = [
        p("DellDockFirmwareUpdateLinux_01.00.20.cab", "0572352b20a0b071331971f0698625afdd140596f2e38a24359aaf25c8ab4cf8",
          "954cce4e10a1d3503c550933b47db0bd96e0eec2997076fa6eedda1166ab8729", [5, 7, 4], esm05_06, true, verified: true),
        p("DellDockFirmwareUpdateLinux_01.00.31.cab", "34283f0745bb6290ddd6ec37a94a6aed1be3ed144924e6e6faa339a2026414ff",
          "6c27d4d011347e1a45e43101fd658ca199453793772d311e6ac90571ae7f38c3", [5, 7, 8], esm05_06, true),
        p("DellDockFirmwareUpdateLinux_01.00.28.cab", "cf16c3d1c0adda35a41763b4b112bba915a262f396bfe025481fb896dca5be8c",
          "ee4b07db0737e5b0e89f8bb0d1302f95ee21042fa154dd4f20a6c48f124168ba", [5, 7, 7], esm05_06, true),
        p("DellDockFirmwareUpdateLinux_01.00.08.cab", "c1f5b189997e3b1a97b10c4b723348498d3cb5821ca8ec872f2d72b2748dd873",
          "ee4b07db0737e5b0e89f8bb0d1302f95ee21042fa154dd4f20a6c48f124168ba", [5, 7, 7], esm05_06, true),
        p("DellDockFirmwareUpdateLinux_01.00.06.cab", "c0a79e4cb0a02746708497d16ec8e689fa33db7c6ac987cf6e6ebb0f4ad17eea",
          "ee4b07db0737e5b0e89f8bb0d1302f95ee21042fa154dd4f20a6c48f124168ba", [5, 7, 7], esm05_06, true),
        p("DellDockFirmwareUpdateLinux_01.00.16.cab", "b1275193349c3ebd1db3821462143ac859302afe3572060fab7ee4793b4892bd",
          "14629a7d87030ad7a14f5e91c00bb852d8348d70506422b6b00ad969f59b75f2", [5, 7, 1], esm05_06, true),
        p("DellDockFirmwareUpdateLinux_01.00.09.cab", "03ff7f61284b6d3c6dcab2644f1cdf701c650ad4270b93590c5eb4f6d8571192",
          "b32a25e84fb0eee9eb518e103b5a681118df0014f908c52782f075c94fa3f3f7", [5, 6, 3], esm05_06, false),
        p("WD19FirmwareUpdateLinux_01.00.15.cab", "9b638b7a90e2c2071a796ac4b544ed14ead1a610ff411078b4660dc0ca778439",
          "d793d2c8ae780f422b287afc96c92b1366032db201294a968fc5e6214b34312e", [5, 4, 6], esm05_04, false),
        p("WD19FirmwareUpdateLinux_01.00.14.cab", "b6c46055ee3ad82bca69ba6bb50b4321012c7fa042d4417cca0cbb615eb937ae",
          "0e3d06ce59892d098cd427faa5c50215cd4b6dd0968a0284112d5dcfab56652f", [5, 4, 3], esm05_04, false),
        p("WD19FirmwareUpdateLinux_01.00.04.cab", "ab1b5bd6fbbeaf8d0ddd1197e9a54f8c55fe8fefe30a8b54aaa836e50c917e3f",
          "1eaf05d93c583053143c744339240cd1e606faa2d8cad2c22661140527b4ffcb", [0x05, 0x03, 0x10], esm05_04, false),
    ]

    private static func p(_ n: String, _ cab: String, _ img: String, _ v: [UInt8], _ esm: UInt32, _ target: Bool, verified: Bool = false) -> KnownPackage {
        KnownPackage(fileName: n, cabSHA256: cab, hubImageSHA256: img, hubVersion: v, esmSum32: esm, flashTarget: target,
                     url: lvfs(cab, n), urlVerified: verified)
    }

    /// The last hub firmware with ViewXpand (05.07.04, package 01.00.20).
    public static var viewXpandPackage: KnownPackage { packages[0] }
    /// Newest package in this table (05.07.08, 01.00.31). Not necessarily Dell's newest release.
    public static var latestPackage: KnownPackage { packages[1] }

    public static func package(cabSHA256 sha: String) -> KnownPackage? { packages.first { $0.cabSHA256 == sha.lowercased() } }
    public static func package(hubImageSHA256 sha: String) -> KnownPackage? { packages.first { $0.hubImageSHA256 == sha.lowercased() } }
}
