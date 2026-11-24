// Test fixtures: the real flash dump and Dell packages, when present on this machine.
// Override locations with DOCKDESK_FWDUMP_DIR / DOCKDESK_CAB_DIR. Tests that need them are disabled
// (not failed) when the files are missing.

import Foundation
@testable import FirmwareKit

enum TD {
    static let env = ProcessInfo.processInfo.environment
    static let dumpDir = env["DOCKDESK_FWDUMP_DIR"] ?? "testdata/fwdump"
    static let cabDir = env["DOCKDESK_CAB_DIR"]
        ?? "testdata/packages"

    static let dump: [UInt8]? = {
        guard let a = try? Data(contentsOf: URL(fileURLWithPath: dumpDir + "/flash_0_40000.bin")),
              let b = try? Data(contentsOf: URL(fileURLWithPath: dumpDir + "/flash_40000_80000.bin")),
              a.count + b.count == Panamera.flashSize else { return nil }
        return [UInt8](a + b)
    }()

    static func cabURL(_ name: String) -> URL { URL(fileURLWithPath: cabDir + "/" + name) }
    static func haveCab(_ name: String) -> Bool { FileManager.default.fileExists(atPath: cabDir + "/" + name) }

    static let cab0704 = "DellDockFirmwareUpdateLinux_01.00.20.cab"
    static let cab0708 = "DellDockFirmwareUpdateLinux_01.00.31.cab"
    static let cab0406 = "WD19FirmwareUpdateLinux_01.00.15.cab"

    static let img0704: VMMImage? = haveCab(cab0704) ? try? FirmwarePackage.loadHubImage(fromCab: cabURL(cab0704)) : nil
    static let img0708: VMMImage? = haveCab(cab0708) ? try? FirmwarePackage.loadHubImage(fromCab: cabURL(cab0708)) : nil

    static var haveDump: Bool { dump != nil }
    static var haveDumpAnd0704: Bool { dump != nil && img0704 != nil }
    static var haveAll: Bool { dump != nil && img0704 != nil && img0708 != nil }

    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fwkit-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static let ac = FixedPowerSource(true)

    /// Simulator in the state of the dump (05.07.08 running from bank 1, bank 0 tag sector erased).
    static func dumpHub(_ policy: SimulatedHub.BothValidPolicy = .preferBank0) -> SimulatedHub {
        SimulatedHub(flash: dump!, bothValidPolicy: policy)
    }

    /// Backup into a temp dir; the files are deleted again unless `keep` (the result keeps the bytes).
    static func backup(of hub: SimulatedHub, keep: Bool = false) throws -> VerifiedBackup {
        let dir = tempDir()
        let b = try Backup.create(transport: hub, directory: dir, now: Date(timeIntervalSince1970: 1_764_000_000))
        if !keep { try? FileManager.default.removeItem(at: dir) }
        return b
    }

    /// Code hashes of every firmware we consider intact.
    static var intactCode: Set<String> {
        var s = Set<String>()
        if let d = dump { s.insert(Checksum.sha256(Data(d[0x20000..<0x3F000]))) }
        for img in [img0704, img0708].compactMap({ $0 }) { s.insert(Checksum.sha256(Data(img.bytes[0..<0x1F000]))) }
        return s
    }

    static func silent(_ s: String) {}
}

/// Forwards to a hub but corrupts one flash read after `corruptAfterReads` reads.
final class FlakyTransport: HubTransport {
    let inner: HubTransport
    var reads = 0
    let corruptAt: Int
    init(_ inner: HubTransport, corruptRead n: Int) { self.inner = inner; corruptAt = n }
    func dpcdRead(_ a: UInt32, count: Int) throws -> [UInt8] { try inner.dpcdRead(a, count: count) }
    func rcEnable() throws { try inner.rcEnable() }
    func rcDisable() throws { try inner.rcDisable() }
    func rcReadMemory(_ a: UInt32, count: Int) throws -> [UInt8] { try inner.rcReadMemory(a, count: count) }
    func rcReadFlash(_ a: UInt32, count: Int) throws -> [UInt8] {
        var b = try inner.rcReadFlash(a, count: count)
        reads += 1
        if reads == corruptAt { b[0] ^= 0x40 }
        return b
    }
    func rcFlashSum32(_ a: UInt32, length: UInt32) throws -> UInt32 { try inner.rcFlashSum32(a, length: length) }
    func rcFlashCRC16(_ a: UInt32, length: UInt32) throws -> UInt32 { try inner.rcFlashCRC16(a, length: length) }
    func rcWriteMemory(_ a: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws { try inner.rcWriteMemory(a, bytes: bytes, auth) }
    func rcEraseFlash(code: UInt16, _ auth: WriteAuthorization) throws { try inner.rcEraseFlash(code: code, auth) }
    func rcWriteFlash(_ a: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws { try inner.rcWriteFlash(a, bytes: bytes, auth) }
    func sleep(milliseconds: Int) {}
}
