import CDock
import FirmwareKit
import Foundation

/// `dockdeskctl fw ...`: staged hardware checks for the hub flasher (docs/flasher.md section 11).
func firmwareCommand(_ args: [String]) {
    guard let dock = td_open() else { fail("no dock") }
    defer { td_close(dock) }
    let t = CDockTransport(dock: dock)
    let backupDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DockDesk/Backups")
    func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    func hexs(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }
    func latestBackup() throws -> VerifiedBackup {
        if let p = value("--backup") { return try Backup.load(URL(fileURLWithPath: p)) }
        let bins = (try? FileManager.default.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: [.contentModificationDateKey]))?.filter { $0.pathExtension == "bin" } ?? []
        guard let newest = bins.max(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) else { fail("no backup in \(backupDir.path); run: dockdeskctl fw backup") }
        return try Backup.load(newest)
    }
    do {
        switch args.first ?? "" {
        case "state": // E1, read-only
            let id = try DeviceReader.identity(t)
            print("chip \(String(format: "%04x", id.chipId)) firmware \(id.firmwareString) rc=\(id.rcCapable)")
            try t.rcEnable(); defer { try? t.rcDisable() }
            let st = try t.rcReadMemory(Panamera.regBootStatus, count: 16)
            print("boot status 0x20010C: \(hexs(st))  -> running bank \(DeviceSnapshot.activeBank(fromBootStatus: UInt32(st[0]) | UInt32(st[1]) << 8 | UInt32(st[2]) << 16 | UInt32(st[3]) << 24))")
            for b in 0..<2 { print("tag bank \(b): \(hexs(try t.rcReadFlash(UInt32(Panamera.bankBase(b) + Panamera.tagOffset), count: 16)))") }
            print("board id RAM 0x170E: \(hexs(try t.rcReadMemory(Panamera.ramBoardId, count: 2)))")
            print("quad  0x200FC0: \(hexs(try t.rcReadMemory(Panamera.regQuadDisable, count: 16)))")
            print("hdcp  0x200F90: \(hexs(try t.rcReadMemory(Panamera.regHDCP22Disable, count: 4)))")
        case "backup": // E2, read-only
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            var last = -1
            let b = try Backup.create(transport: t, directory: backupDir) { done, total in
                let pct = done * 100 / max(total, 1)
                if pct / 10 != last / 10 { last = pct; FileHandle.standardError.write("  \(pct)%\n".data(using: .utf8)!) }
            }
            print("backup \(b.url.path)")
            print("  firmware \(b.record.firmwareVersion), running bank \(b.record.activeBank), sha256 \(b.record.sha256.prefix(16))…")
            for bank in b.analysis.banks { print("  bank \(bank.index): version \(formatVersion(bank.version)) tag \(bank.tag) valid=\(bank.tagValid) wd19=\(bank.looksLikeWD19Firmware) sum \(String(format: "0x%08x", bank.sum32))") }
            print("  esm sum \(String(format: "0x%08x", b.analysis.esmSum32))")
        case "checksum": // E3 part 1, read-only
            let b = try latestBackup()
            try t.rcEnable(); defer { try? t.rcDisable() }
            for (a, l) in [(0, 32), (0, 0x20000), (0x20000, 0x20000), (0x40000, 0x40000)] {
                let t0 = Date()
                let chip = try t.rcFlashSum32(UInt32(a), length: UInt32(l))
                let mine = b.bytes[a..<(a + l)].reduce(UInt32(0)) { $0 &+ UInt32($1) }
                print(String(format: "sum 0x%05x+0x%05x: hub 0x%08x backup 0x%08x %@ (%.0f ms)", a, l, chip, mine, chip == mine ? "MATCH" : "DIFFERENT", Date().timeIntervalSince(t0) * 1000))
            }
            if args.contains("--crc16") {
                let chip = try t.rcFlashCRC16(0, length: 0x1A000)
                print(String(format: "crc16 0x00000+0x1a000: hub 0x%04x", chip))
            }
        case "flash": // dry run unless --write
            guard let cab = value("--cab") else { fail("usage: dockdeskctl fw flash --cab <dell.cab> [--split-default] [--write] [--stop-after <stage>] [--rc-reboot]") }
            let image = try FirmwarePackage.loadHubImage(fromCab: URL(fileURLWithPath: cab))
            let backup = try latestBackup()
            let snap = try DeviceReader.snapshot(t)
            var opts = FlashOptions()
            if args.contains("--rc-reboot") { opts.restart = .rcReboot }
            let target = args.contains("--split-default") ? try FlashTarget.splitDefault(image) : try FlashTarget.dell(image)
            let plan = try FlashPlanner.plan(snapshot: snap, target: target, backup: backup, power: SystemPowerSource(), options: opts)
            print(plan.summary())
            let write = args.contains("--write")
            let stop = value("--stop-after").flatMap(StageKind.init(rawValue:))
            if value("--stop-after") != nil && stop == nil { fail("unknown stage") }
            t.armForWrites = write
            var lines = 0
            let exec = FlashExecutor(transport: t) { line in
                lines += 1
                if lines < 60 || lines % 400 == 0 || !line.contains("0x20") { print(line) }
            }
            let rep = try exec.execute(plan, allowWrites: write, stopAfter: stop)
            print("dryRun=\(rep.dryRun) stages=\(rep.completedStages.map(\.rawValue)) sent=\(rep.mutatingOpsSent) skipped=\(rep.mutatingOpsSkipped) verified=\(rep.verificationsCompared) unverified=\(rep.verificationsSkipped)")
            print(rep.nextStep)
        default:
            fail("usage: dockdeskctl fw state | backup | checksum [--crc16] | flash --cab <file> [--split-default] [--write] [--stop-after <stage>]")
        }
    } catch { fail("fw: \(error)") }
}
