// SPDX-License-Identifier: LGPL-2.1-or-later
// The single guarded entry point that can modify the hub.

import Foundation

/// Proof that a mutating transport call comes from `FlashExecutor.execute(_:allowWrites: true)`.
/// The initialiser is fileprivate: no other file can create one, so no other code path can call
/// `rcWriteMemory`, `rcEraseFlash` or `rcWriteFlash` on a transport.
public struct WriteAuthorization {
    fileprivate init() {}
}

public enum ExecutorError: Error, CustomStringConvertible {
    case refused(String)
    case verificationFailed(stage: StageKind, op: String, detail: String)
    case transport(stage: StageKind, op: String, underlying: Error)

    public var description: String {
        switch self {
        case .refused(let s): return "refused: \(s)"
        case .verificationFailed(let st, let op, let d): return "verification failed in \(st.rawValue): \(op): \(d)"
        case .transport(let st, let op, let e): return "transport error in \(st.rawValue) during \(op): \(e)"
        }
    }
}

public struct ExecutionReport {
    public var dryRun: Bool
    public var completedStages: [StageKind] = []
    public var mutatingOpsSent = 0
    public var mutatingOpsSkipped = 0
    public var verificationsCompared = 0
    public var verificationsSkipped = 0
    /// What the user has to do next.
    public var nextStep = ""
}

public final class FlashExecutor {
    let transport: HubTransport
    let log: (String) -> Void

    public init(transport: HubTransport, log: @escaping (String) -> Void = { print($0) }) {
        self.transport = transport
        self.log = log
    }

    /// Run `plan`. Default is a dry run: every read and verification read is performed, every
    /// erase/write is logged but not sent. With `allowWrites: true` the plan must validate and carry a
    /// passing guard report. Stops at the first failed verification; nothing after it is sent, in
    /// particular the old bank is never invalidated unless the new bank and its tag verified.
    ///
    /// `stopAfter` ends the run after that stage (RC is disabled, no restart). Only stages after which the
    /// running bank is still the only valid one are accepted; `.verifyBody` is the proposed first write
    /// experiment on real hardware (erase + program the inactive bank, never write its tag).
    public static let safeStopPoints: Set<StageKind> = [.preflight, .prepare, .verifyErased, .verifyBody]

    @discardableResult
    public func execute(_ plan: FlashPlan, allowWrites: Bool = false, stopAfter: StageKind? = nil) throws -> ExecutionReport {
        if let s = stopAfter, !FlashExecutor.safeStopPoints.contains(s) {
            throw ExecutorError.refused("cannot stop after \(s.rawValue): would leave two valid tags or a half-finished invalidation")
        }
        do { try plan.validate() } catch { throw ExecutorError.refused("plan does not validate: \(error)") }
        guard plan.guards.ok else { throw ExecutorError.refused("guards failed: \(plan.guards.failures)") }
        let auth: WriteAuthorization? = allowWrites ? WriteAuthorization() : nil
        var report = ExecutionReport(dryRun: !allowWrites)
        var mutated = false   // in a dry run: a skipped write precedes, so later comparisons are meaningless
        log(allowWrites ? "EXECUTING (writes enabled)" : "DRY RUN (no erase/write will be sent)")

        var rcOpen = false
        defer { if rcOpen { try? transport.rcDisable() } }

        for stage in plan.stages {
            log("== stage \(stage.kind.rawValue)")
            for op in stage.ops {
                do {
                    switch op {
                    case .rcEnable:
                        try transport.rcEnable(); rcOpen = true
                    case .rcDisable:
                        try transport.rcDisable(); rcOpen = false
                    case .sleep(let ms):
                        transport.sleep(milliseconds: allowWrites ? ms : 0)
                    case .expectActiveBank, .expectMemory, .expectFlash, .expectSum32, .expectCRC16:
                        let problem = try check(op)
                        if !allowWrites && mutated {
                            report.verificationsSkipped += 1
                            log("   (dry run) read done, not compared: \(op)")
                        } else if let p = problem {
                            log("!! \(op): \(p)")
                            throw ExecutorError.verificationFailed(stage: stage.kind, op: op.description, detail: p)
                        } else {
                            report.verificationsCompared += 1
                        }
                    case .writeMemory, .eraseFlash, .writeFlash, .reboot:
                        guard let auth = auth else {
                            report.mutatingOpsSkipped += 1
                            if case .writeMemory = op {} else { mutated = true }
                            log("   WOULD SEND \(op)")
                            continue
                        }
                        try send(op, auth)
                        report.mutatingOpsSent += 1
                        if op == .reboot { rcOpen = false }
                    }
                } catch let e as ExecutorError {
                    throw e
                } catch {
                    log("!! transport error in \(stage.kind.rawValue) at \(op): \(error)")
                    throw ExecutorError.transport(stage: stage.kind, op: op.description, underlying: error)
                }
            }
            report.completedStages.append(stage.kind)
            if stage.kind == stopAfter {
                if rcOpen { try? transport.rcDisable(); rcOpen = false }
                report.nextStep = "stopped after \(stage.kind.rawValue); running bank untouched. Power-cycle the dock to undo the RAM changes of the prepare stage."
                log(report.nextStep)
                return report
            }
        }
        report.nextStep = plan.options.restart == .rcReboot
            ? "hub restart requested; re-read DPCD 0x50A and RAM 0x20010c to confirm"
            : "unplug the dock's power adapter for 10 seconds, plug it back, then confirm the version"
        log(allowWrites ? "done: \(report.nextStep)" : "dry run done: \(report.mutatingOpsSkipped) mutating ops would have been sent")
        return report
    }

    /// Returns nil if the expectation holds, otherwise a description of the mismatch.
    private func check(_ op: FlashOp) throws -> String? {
        switch op {
        case .expectActiveBank(let b):
            let s = try transport.readU32LE(memory: Panamera.regBootStatus)
            let got = DeviceSnapshot.activeBank(fromBootStatus: s)
            return got == b ? nil : "active bank \(got) (status \(h32(s)))"
        case .expectMemory(let a, let want):
            let got = try transport.rcReadMemory(a, count: want.count)
            return got == want ? nil : "read \(hex(got))"
        case .expectFlash(let a, let want):
            let got = try transport.rcReadFlash(a, count: want.count)
            if got == want { return nil }
            let i = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? 0
            return String(format: "first difference at %@: read %02x expected %02x", h(Int(a) + i), got[i], want[i])
        case .expectSum32(let a, let l, let v):
            let got = try transport.rcFlashSum32(a, length: l)
            return got == v ? nil : "chip sum \(h32(got))"
        case .expectCRC16(let a, let l, let v):
            let got = try transport.rcFlashCRC16(a, length: l)
            return got == v ? nil : "chip crc \(h32(got))"
        default:
            return "not a verification op"
        }
    }

    private func send(_ op: FlashOp, _ auth: WriteAuthorization) throws {
        log("   SEND \(op)")
        switch op {
        case .writeMemory(let a, let b):
            try transport.rcWriteMemory(a, bytes: b, auth)
        case .eraseFlash(let c):
            try transport.rcEraseFlash(code: c, auth)
        case .writeFlash(let a, let b):
            do { try transport.rcWriteFlash(a, bytes: b, auth) } catch {
                // fwupd retries a failed chunk write once ("repeat once").
                log("   retrying write at \(h(Int(a))) after \(error)")
                try transport.rcWriteFlash(a, bytes: b, auth)
            }
        case .reboot:
            // fwupd ignores the result: the hub restarts before it can answer.
            do { try transport.rcWriteMemory(Panamera.regMcuCommand, bytes: [Panamera.mcuCommandReboot, 0, 0, 0], auth) } catch {
                log("   restart write returned \(error) (expected, ignored as in fwupd)")
            }
        default:
            break
        }
    }

    /// After the hub restarted (power cycle or RC reboot): read-only confirmation.
    public static func confirmAfterRestart(_ t: HubTransport, plan: FlashPlan) throws -> (ok: Bool, detail: String) {
        let id = try DeviceReader.identity(t)
        try t.rcEnable()
        defer { try? t.rcDisable() }
        let bank = DeviceSnapshot.activeBank(fromBootStatus: try t.readU32LE(memory: Panamera.regBootStatus))
        let ok = id.firmware == plan.targetVersion && bank == plan.targetBank
        return (ok, "running \(id.firmwareString) from bank \(bank); expected \(formatVersion(plan.targetVersion)) from bank \(plan.targetBank)")
    }
}
