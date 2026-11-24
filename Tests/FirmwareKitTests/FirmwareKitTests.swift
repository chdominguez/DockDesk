// Offline tests for FirmwareKit. Nothing here touches hardware: every transport is a SimulatedHub.
import Foundation
import Testing
@testable import FirmwareKit

@Suite struct ChecksumAndLayoutTests {
    @Test func crcAlgorithmsMatchFwupdTables() {
        // CRC-16 poly 0x8005, init 0, unreflected ("CRC-16/UMTS") check value.
        #expect(Checksum.crc16(Array("123456789".utf8)) == 0xFEE8)
        // fwupd CRC8_table[1] == 0xd5, CRC16_table[1] == 0x8005.
        #expect(Checksum.crc8([0x01]) == 0xD5)
        #expect(Checksum.crc16([0x01]) == 0x8005)
        // Real tags from the Dell images and the dump.
        let t = BankTag([0x01, 0x01, 0x1D, 0x19, 0x4A, 0x51, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x4F])
        #expect(t.isValid(forBank: 1) && !t.isValid(forBank: 0) && t.hasDellMarker)
        #expect(BankTag.retargeted(t, toBank: 0).bytes.last == 0xA9)   // == Dell 01.00.31 bank 0 tag
        #expect(Checksum.sum32([UInt8](repeating: 0xFF, count: 0x20000)) == 0x01FE_0000)
    }

    @Test func eraseCodes() {
        #expect(Panamera.bankEraseCodes(0) == [0x3000, 0x3001])
        #expect(Panamera.bankEraseCodes(1) == [0x3002, 0x3003])
        #expect(Panamera.tagSectorEraseCode(0) == 0x101F)
        #expect(Panamera.tagSectorEraseCode(1) == 0x103F)
        #expect(Panamera.eraseRange(code: 0x103F) == 0x3F000..<0x40000)
        #expect(Panamera.eraseRange(code: 0x3003) == 0x30000..<0x40000)
        #expect(Panamera.eraseRange(code: 0xFFFF) == nil)
        #expect(DeviceSnapshot.activeBank(fromBootStatus: 0x80) == 1)
        #expect(DeviceSnapshot.activeBank(fromBootStatus: 0x4000_0000) == 1)
        #expect(DeviceSnapshot.activeBank(fromBootStatus: 0x0F) == 0)
    }
}

@Suite struct PackageAndImageTests {
    @Test(.enabled(if: TD.haveCab(TD.cab0704))) func verifiesAndExtractsDellCab() throws {
        let pkg = try FirmwarePackage.verifyCab(at: TD.cabURL(TD.cab0704))
        #expect(pkg.hubVersion == [5, 7, 4] && pkg.urlVerified)
        #expect(pkg.url == "https://fwupd.org/downloads/0572352b20a0b071331971f0698625afdd140596f2e38a24359aaf25c8ab4cf8-DellDockFirmwareUpdateLinux_01.00.20.cab")
        let img = try #require(TD.img0704)
        #expect(Checksum.sha256(img.bytes) == "954cce4e10a1d3503c550933b47db0bd96e0eec2997076fa6eedda1166ab8729")
        #expect(img.analysis.banks.map { $0.version } == [[5, 7, 4], [5, 7, 4]])
        #expect(img.analysis.banks[0].tag.description == "000c0d174a5100000000000000000064")
        #expect(img.analysis.banks[1].tag.description == "010c0d174a5100000000000000000082")
        #expect(img.analysis.banks[0].codeEnd == 0x18406)
    }

    @Test(.enabled(if: TD.haveCab(TD.cab0704))) func refusesTamperedOrUnknownCab() throws {
        let dir = TD.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var data = try Data(contentsOf: TD.cabURL(TD.cab0704))
        data.append(0)
        let bad = dir.appendingPathComponent("tampered.cab")
        try data.write(to: bad)
        #expect(throws: PackageError.self) { try FirmwarePackage.loadHubImage(fromCab: bad) }
        let junk = dir.appendingPathComponent("junk.cab")
        try Data("not a cab".utf8).write(to: junk)
        #expect(throws: PackageError.self) { try FirmwarePackage.verifyCab(at: junk) }
    }

    @Test func parsesEveryKnownPackagePresent() throws {
        var seen = 0
        for p in KnownFirmware.packages where TD.haveCab(p.fileName) {
            let img = try FirmwarePackage.loadHubImage(fromCab: TD.cabURL(p.fileName))
            #expect(img.version == p.hubVersion)
            #expect(VMMImage.structuralProblems(img.bytes).isEmpty)
            if p.flashTarget { _ = try FlashTarget.dell(img) } else {
                #expect(throws: ImageError.self) { try FlashTarget.dell(img) }
            }
            seen += 1
        }
        print("parsed \(seen) known packages")
    }

    @Test(.enabled(if: TD.img0704 != nil)) func refusesModifiedImages() throws {
        let img = try #require(TD.img0704)
        var code = img.bytes
        code[0x8000] ^= 0xFF
        #expect(throws: ImageError.unknownImage(sha256: Checksum.sha256(code))) { try VMMImage.parse(code) }
        var cfg = img.bytes
        cfg[0x150] &+= 1   // breaks the config block checksum in bank 0
        #expect(VMMImage.structuralProblems(cfg).contains { $0.contains("config block checksum") })
        var board = img.bytes
        board[0x10F] = 0x04
        #expect(VMMImage.structuralProblems(board).contains { $0.contains("board id") })
        var tag = img.bytes
        tag[0x1FFFF] ^= 1
        #expect(VMMImage.structuralProblems(tag).contains { $0.contains("tag") })
        #expect(throws: ImageError.wrongSize(100)) { try VMMImage.parse([UInt8](repeating: 0, count: 100)) }
    }

    @Test(.enabled(if: TD.haveDump)) func analysesTheRealDump() throws {
        let a = try FlashAnalysis(TD.dump!)
        #expect(a.validBanks == [1])
        #expect(a.banks[0].tag.isErased && a.banks[0].version == [5, 7, 4])
        #expect(a.banks[1].version == [5, 7, 8] && a.banks[1].tag.description == "01011d194a510000000000000000004f")
        #expect(a.banks.allSatisfy { $0.looksLikeWD19Firmware && $0.tagSectorPaddingOnly })
        #expect(a.esmSum32 == 0x01E4_639E)
        if let img = TD.img0708 { #expect(a.banks[1].bodySHA256 == img.analysis.banks[1].bodySHA256) }
        if let img = TD.img0704 {
            // bank 0 is 05.07.04 whose tag sector was erased by an earlier dell-dock style invalidation
            #expect(Array(TD.dump![0..<0x1F000]) == Array(img.bytes[0..<0x1F000]))
        }
    }
}

@Suite struct BackupTests {
    @Test(.enabled(if: TD.haveDump)) func roundTrip() throws {
        let hub = TD.dumpHub()
        let b = try TD.backup(of: hub, keep: true)
        defer { try? FileManager.default.removeItem(at: b.url.deletingLastPathComponent()) }
        #expect(b.bytes == TD.dump!)
        #expect(b.record.firmwareVersion == "05.07.08" && b.record.activeBank == 1 && b.record.verifiedByReread)
        #expect(b.record.chipId == "0x5331" && b.record.boardId == "0x0103")
        let again = try Backup.load(b.url)
        #expect(again.record == b.record)
        #expect(hub.mutationCount == 0 && !hub.rcEnabled)

        var data = try Data(contentsOf: b.url)
        data[0x1234] ^= 1
        try data.write(to: b.url)
        #expect(throws: BackupError.self) { try Backup.load(b.url) }
        try FileManager.default.removeItem(at: Backup.sidecarURL(for: b.url))
        #expect(throws: BackupError.self) { try Backup.load(b.url) }
    }

    @Test(.enabled(if: TD.haveDump)) func unstableReadsAreRejected() throws {
        let flaky = FlakyTransport(TD.dumpHub(), corruptRead: 128 + 8)   // 8th read of the second pass
        let dir = TD.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: BackupError.rereadMismatch(firstDifference: 7 * 4096)) {
            try Backup.create(transport: flaky, directory: dir)
        }
    }
}

@Suite struct PlanTests {
    func dumpPlan(_ hub: SimulatedHub, options: FlashOptions = FlashOptions()) throws -> FlashPlan {
        let backup = try TD.backup(of: hub)
        let snap = try DeviceReader.snapshot(hub)
        return try FlashPlanner.plan(snapshot: snap, target: try FlashTarget.dell(TD.img0704!), backup: backup,
                                     power: TD.ac, options: options)
    }

    @Test(.enabled(if: TD.haveDumpAnd0704)) func planDumpTo050704() throws {
        let hub = TD.dumpHub()
        let plan = try dumpPlan(hub)
        #expect(hub.mutationCount == 0)
        #expect(plan.runningBank == 1 && plan.targetBank == 0)
        #expect(plan.stages.map { $0.kind } == StageKind.allCases)
        let muts = plan.mutatingOps
        #expect(muts.count == 3 + 2 + 4096 + 1 + 1)
        #expect(Array(muts.prefix(3)) == [
            .writeMemory(address: 0x2000FC, bytes: [0x21, 0, 0, 0]),
            .writeMemory(address: 0x200FC0, bytes: [0, 0, 0, 0]),
            .writeMemory(address: 0x200F90, bytes: [0, 0, 0, 0]),
        ])
        #expect(muts[3] == .eraseFlash(code: 0x3000) && muts[4] == .eraseFlash(code: 0x3001))
        #expect(muts[5] == .writeFlash(address: 0, bytes: Array(TD.img0704!.bytes[0..<32])))
        #expect(muts[muts.count - 3] == .writeFlash(address: 0x1FFE0, bytes: Array(TD.img0704!.bytes[0x1FFE0..<0x1FFF0])))
        #expect(muts[muts.count - 2] == .writeFlash(address: 0x1FFF0, bytes: TD.img0704!.analysis.banks[0].tag.bytes))
        #expect(muts.last == .eraseFlash(code: 0x103F))
        #expect(plan.targetContent == TD.img0704!.bankContent(for: 0))
        #expect(plan.summary().contains("invalidateOld"))
    }

    @Test(.enabled(if: TD.haveDumpAnd0704)) func dryRunSendsNothing() throws {
        let hub = TD.dumpHub()
        let plan = try dumpPlan(hub)
        var lines: [String] = []
        let report = try FlashExecutor(transport: hub, log: { lines.append($0) }).execute(plan)
        #expect(report.dryRun && report.mutatingOpsSent == 0 && report.mutatingOpsSkipped == plan.mutatingOps.count)
        #expect(report.completedStages == StageKind.allCases)
        #expect(lines.filter { $0.contains("WOULD SEND") }.count == plan.mutatingOps.count)
        #expect(hub.flash == TD.dump! && hub.mutationCount == 0 && hub.runningBank == 1)
        #expect(report.verificationsCompared >= 10)
    }

    @Test(.enabled(if: TD.haveDumpAnd0704), arguments: [RestartMethod.userPowerCycle, .rcReboot])
    func executesDumpTo050704(restart: RestartMethod) throws {
        let hub = TD.dumpHub()
        var opts = FlashOptions()
        opts.restart = restart
        opts.verifyWithCRC16 = true
        let plan = try dumpPlan(hub, options: opts)
        let report = try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true)
        #expect(report.mutatingOpsSent == plan.mutatingOps.count)
        if restart == .userPowerCycle { hub.powerCycle() }
        #expect(hub.runningBank == 0)
        #expect(try DeviceReader.identity(hub).firmware == [5, 7, 4])
        #expect(try FlashExecutor.confirmAfterRestart(hub, plan: plan).ok)
        let img = TD.img0704!
        #expect(Array(hub.flash[0..<0x20000]) == img.bankContent(for: 0))
        #expect(Array(hub.flash[0x20000..<0x3F000]) == Array(TD.dump![0x20000..<0x3F000]))
        #expect(hub.flash[0x3F000..<0x40000].allSatisfy { $0 == 0xFF })
        #expect(Array(hub.flash[0x40000...]) == Array(TD.dump![0x40000...]))
        #expect(hub.programViolations == 0)
        #expect(hub.runningBankErases == [0x103F])
        #expect(hub.bootCandidates == [0])
    }

    @Test(.enabled(if: TD.haveDumpAnd0704)) func badWriteStopsBeforeTagAndInvalidation() throws {
        let hub = TD.dumpHub()
        let plan = try dumpPlan(hub)
        hub.corruptWritesAt = [0x9000]
        #expect(throws: ExecutorError.self) { try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true) }
        #expect(hub.tag(0).isErased)                     // new tag never written
        #expect(hub.tag(1).isValid(forBank: 1))          // old bank untouched
        #expect(hub.runningBankErases.isEmpty)
        #expect(!hub.rcEnabled)
        hub.powerCycle()
        let fw = try DeviceReader.identity(hub).firmware
        #expect(hub.runningBank == 1 && fw == [5, 7, 8])
    }

    @Test(.enabled(if: TD.haveDumpAnd0704)) func firstHardwareExperimentStopsBeforeTag() throws {
        let hub = TD.dumpHub()
        let plan = try dumpPlan(hub)
        #expect(throws: ExecutorError.self) {
            try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true, stopAfter: .writeTag)
        }
        #expect(hub.mutationCount == 0)
        let r = try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true, stopAfter: .verifyBody)
        #expect(r.completedStages.last == .verifyBody && !hub.rcEnabled)
        #expect(Array(hub.flash[0..<0x1FFF0]) == Array(TD.img0704!.bytes[0..<0x1FFF0]) && hub.tag(0).isErased)
        #expect(hub.runningBankErases.isEmpty && hub.programViolations == 0)
        hub.powerCycle()
        let fw = try DeviceReader.identity(hub).firmware
        #expect(hub.runningBank == 1 && fw == [5, 7, 8])
    }

    @Test(.enabled(if: TD.haveDumpAnd0704)) func executorRefusesTamperedPlan() throws {
        let hub = TD.dumpHub()
        let p = try dumpPlan(hub)
        var stages = p.stages
        stages[2] = FlashStage(kind: .eraseInactive, ops: stages[2].ops + [.eraseFlash(code: 0x3002)])  // running bank!
        let bad = FlashPlan(snapshot: p.snapshot, targetDescription: p.targetDescription, targetVersion: p.targetVersion,
                            runningBank: p.runningBank, targetBank: p.targetBank, targetContent: p.targetContent,
                            options: p.options, guards: p.guards, stages: stages)
        #expect(throws: ExecutorError.self) { try FlashExecutor(transport: hub, log: TD.silent).execute(bad, allowWrites: true) }
        var stages2 = p.stages
        stages2[1] = FlashStage(kind: .prepare, ops: [.writeMemory(address: 0x1740, bytes: [2, 0, 0, 0])])
        let bad2 = FlashPlan(snapshot: p.snapshot, targetDescription: "", targetVersion: p.targetVersion, runningBank: 1,
                             targetBank: 0, targetContent: p.targetContent, options: p.options, guards: p.guards, stages: stages2)
        #expect(throws: PlanError.self) { try bad2.validate() }
        #expect(hub.mutationCount == 0)
    }
}

@Suite struct PowerLossTests {
    /// Every boundary between mutating commands (and before the first) leaves a device that boots intact code.
    @Test(.enabled(if: TD.haveDumpAnd0704)) func everyBoundaryIsBootable() throws {
        let hub = TD.dumpHub()
        let backup = try TD.backup(of: hub)
        let plan = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: try FlashTarget.dell(TD.img0704!),
                                         backup: backup, power: TD.ac)
        let intact = TD.intactCode
        var boundaries = 0, bad: [Int] = []
        #expect(hub.isBootable(intactCode: intact))
        hub.onMutation = { h in
            boundaries += 1
            if !h.isBootable(intactCode: intact) { bad.append(h.mutationCount) }
        }
        try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true)
        #expect(boundaries == plan.mutatingOps.count)
        #expect(bad.isEmpty, "unbootable after mutation(s) \(bad.prefix(5))")
    }

    /// Real interruptions (clean and torn) at every non-body operation and at sampled body writes,
    /// for both possible ROM choices when two tags are valid, followed by a successful re-run.
    @Test(.enabled(if: TD.haveDumpAnd0704), arguments: [SimulatedHub.BothValidPolicy.preferBank0, .preferBank1])
    func interruptAndRecover(policy: SimulatedHub.BothValidPolicy) throws {
        let probe = TD.dumpHub(policy)
        let plan0 = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(probe), target: try FlashTarget.dell(TD.img0704!),
                                          backup: try TD.backup(of: probe), power: TD.ac)
        let n = plan0.mutatingOps.count
        var points = Array(0..<6) + [6, 7, 2000, n - 4, n - 3, n - 2, n - 1]
        points = Array(Set(points)).sorted()
        let intact = TD.intactCode
        for i in points {
            for torn in [false, true] {
                let hub = TD.dumpHub(policy)
                let plan = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: try FlashTarget.dell(TD.img0704!),
                                                 backup: try TD.backup(of: hub), power: TD.ac)
                hub.powerFailAtMutation = i
                hub.tornLastOp = torn
                #expect(throws: ExecutorError.self) { try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true) }
                hub.powerCycle()
                #expect(hub.isBootable(intactCode: intact), "op \(i) torn \(torn): not bootable")
                guard hub.runningBank != nil else { continue }
                // Recovery: new backup (device changed), new plan, run to completion.
                let plan2 = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: try FlashTarget.dell(TD.img0704!),
                                                  backup: try TD.backup(of: hub), power: TD.ac)
                try FlashExecutor(transport: hub, log: TD.silent).execute(plan2, allowWrites: true)
                hub.powerCycle()
                #expect(try DeviceReader.identity(hub).firmware == [5, 7, 4], "op \(i) torn \(torn): recovery")
                #expect(hub.bootCandidates.count == 1)
            }
        }
    }
}

@Suite struct RefusalTests {
    func attempt(_ hub: SimulatedHub, backup: VerifiedBackup?, power: PowerSourceProvider = TD.ac,
                 target: FlashTarget? = nil) throws -> [GuardFailure] {
        let snap = try DeviceReader.snapshot(hub)
        do {
            _ = try FlashPlanner.plan(snapshot: snap, target: try target ?? FlashTarget.dell(TD.img0704!), backup: backup, power: power)
            return []
        } catch PlanError.guardsFailed(let f) { return f }
    }

    @Test(.enabled(if: TD.haveDumpAnd0704)) func refusals() throws {
        let good = TD.dumpHub()
        let backup = try TD.backup(of: good)

        let chip = TD.dumpHub(); chip.chipId = 0x5332
        #expect(try attempt(chip, backup: backup).contains(.wrongChip(0x5332)))

        let oui = TD.dumpHub(); oui.oui = [0x00, 0x1C, 0xF8]
        #expect(try attempt(oui, backup: backup).contains(.wrongOUI([0x00, 0x1C, 0xF8])))

        let board = TD.dumpHub(); board.overrideBoardId([0x01, 0x07])
        #expect(try attempt(board, backup: backup).contains(.wrongBoard(0x0107)))

        let cfg = TD.dumpHub(); cfg.overrideConfigSignature([0x20, 0x00, 0x83, 0x00])
        #expect(try attempt(cfg, backup: backup).contains(.badConfigSignature([0x20, 0x00, 0x83, 0x00])))

        #expect(try attempt(good, backup: nil) == [.noBackup])
        #expect(try attempt(good, backup: backup, power: FixedPowerSource(false)) == [.onBattery])
        #expect(try attempt(good, backup: backup, power: FixedPowerSource(nil)) == [.powerUnknown])
        #expect(try attempt(good, backup: backup).isEmpty)

        // A backup of a different state of the device is not accepted.
        let other = TD.dumpHub()
        other.flash[0x20100] ^= 0  // same running bank bytes...
        other.flash[0x25000] ^= 0x01 // ...except one code byte
        #expect(try attempt(other, backup: backup).contains { if case .backupDoesNotMatchDevice = $0 { return true }; return false })

        // Running bank tag not valid (device booted some other way): refuse.
        let weird = TD.dumpHub()
        weird.flash[0x3FFFF] ^= 0x01   // breaks crc of the running tag without rebooting the sim
        #expect(try attempt(weird, backup: backup).contains { if case .runningBankTagInvalid = $0 { return true }; return false })
        #expect(good.mutationCount + chip.mutationCount + weird.mutationCount == 0)
    }

    @Test(.enabled(if: TD.haveDumpAnd0704 && TD.haveCab(TD.cab0406))) func refusesOtherESM() throws {
        let old = try FirmwarePackage.loadHubImage(fromCab: TD.cabURL(TD.cab0406))
        #expect(throws: ImageError.self) { try FlashTarget.dell(old) }
        let hub = TD.dumpHub()
        let f = try attempt(hub, backup: try TD.backup(of: hub), target: try FlashTarget.dell(old, requireFlashTarget: false))
        #expect(f.contains { if case .esmMismatch = $0 { return true }; return false })
    }
}

@Suite struct RestoreTests {
    @Test(.enabled(if: TD.haveAll)) func restoreBackupAfterDowngrade() throws {
        // Downgrade the simulated dump-state dock to 05.07.04 first.
        let hub = TD.dumpHub()
        let oldBackup = try TD.backup(of: hub)
        let p1 = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: try FlashTarget.dell(TD.img0704!),
                                       backup: oldBackup, power: TD.ac)
        try FlashExecutor(transport: hub, log: TD.silent).execute(p1, allowWrites: true)
        hub.powerCycle()
        #expect(try DeviceReader.identity(hub).firmware == [5, 7, 4])

        // The old backup no longer matches the device, so it cannot serve as the safety backup.
        let restore = try FlashTarget.restore(from: oldBackup, knownImages: [TD.img0704!, TD.img0708!])
        #expect(!restore.synthesizedTag && restore.version == [5, 7, 8])
        #expect(throws: PlanError.self) {
            try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: restore, backup: oldBackup, power: TD.ac)
        }
        let p2 = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: restore,
                                       backup: try TD.backup(of: hub), power: TD.ac)
        #expect(p2.targetBank == 1 && p2.targetContent == TD.img0708!.bankContent(for: 1))
        try FlashExecutor(transport: hub, log: TD.silent).execute(p2, allowWrites: true)
        hub.powerCycle()
        let fw = try DeviceReader.identity(hub).firmware
        #expect(hub.runningBank == 1 && fw == [5, 7, 8])
        #expect(hub.programViolations == 0)
    }

    @Test(.enabled(if: TD.haveAll)) func restoreWithoutKnownImageNeedsExplicitFlag() throws {
        let backup = try TD.backup(of: TD.dumpHub())
        #expect(throws: ImageError.self) { try FlashTarget.restore(from: backup, knownImages: []) }
        let t = try FlashTarget.restore(from: backup, knownImages: [], allowSynthesizedTag: true)
        #expect(t.synthesizedTag)
        // For Dell firmware the synthesized tag equals the one Dell shipped for that bank.
        #expect(t.content(forBank: 0) == TD.img0708!.bankContent(for: 0))
        #expect(t.content(forBank: 1) == TD.img0708!.bankContent(for: 1))
    }

    @Test(.enabled(if: TD.img0704 != nil)) func splitDefaultDiffersInExactlyTwoBytes() throws {
        let dell = try FlashTarget.dell(TD.img0704!), split = try FlashTarget.splitDefault(TD.img0704!)
        for bank in 0..<2 {
            let a = dell.content(forBank: bank), b = split.content(forBank: bank)
            let diff = a.indices.filter { a[$0] != b[$0] }
            #expect(diff == [FlashTarget.modeByteOffset, FlashTarget.configChecksumOffset])
            #expect(a[0x140] == 0x03 && b[0x140] == 0x02)
            #expect(Checksum.sum32(a) == Checksum.sum32(b))
            let info = BankInfo.inspect(bank: bank, ArraySlice(b))
            #expect(info.looksLikeWD19Firmware && info.tagValid && info.tagSectorPaddingOnly)
        }
    }

    @Test(.enabled(if: TD.haveAll)) func splitDefaultOnlyFor050704() throws {
        #expect(throws: ImageError.self) { try FlashTarget.splitDefault(TD.img0708!) }
    }

    /// Dell 05.07.04 -> split default -> back to Dell 05.07.04, all on the simulator.
    @Test(.enabled(if: TD.haveDumpAnd0704)) func splitDefaultInstallAndReturn() throws {
        let hub = TD.dumpHub()
        for target in [try FlashTarget.dell(TD.img0704!), try FlashTarget.splitDefault(TD.img0704!), try FlashTarget.dell(TD.img0704!)] {
            let plan = try FlashPlanner.plan(snapshot: try DeviceReader.snapshot(hub), target: target, backup: try TD.backup(of: hub), power: TD.ac)
            let rep = try FlashExecutor(transport: hub, log: TD.silent).execute(plan, allowWrites: true)
            #expect(!rep.dryRun)
            hub.powerCycle()
            let snap = try DeviceReader.snapshot(hub)
            #expect(snap.activeBank == plan.targetBank)
            let base = Panamera.bankBase(plan.targetBank)
            #expect(Array(hub.flash[base..<(base + Panamera.bankSize)]) == target.content(forBank: plan.targetBank))
            #expect(hub.programViolations == 0)
        }
    }

    @Test(.enabled(if: TD.haveAll)) func dellLatestTarget() throws {
        let t = try FlashTarget.dell(TD.img0708!)
        #expect(t.version == [5, 7, 8] && KnownFirmware.latestPackage.hubVersion == [5, 7, 8])
    }
}
