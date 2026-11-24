// SPDX-License-Identifier: LGPL-2.1-or-later
// Plan generation: device state + target -> ordered operations with exact addresses and bytes.
// The procedure is fwupd's (dell-dock write order and content, synaptics-mst DPCD command forms);
// see docs/flasher.md for the step-by-step mapping and the deviations.

import Foundation

public enum FlashOp: Equatable, CustomStringConvertible {
    case rcEnable
    case rcDisable
    case sleep(ms: Int)
    // read-only verification
    case expectActiveBank(Int)
    case expectMemory(address: UInt32, bytes: [UInt8])
    case expectFlash(address: UInt32, bytes: [UInt8])
    case expectSum32(address: UInt32, length: UInt32, value: UInt32)
    case expectCRC16(address: UInt32, length: UInt32, value: UInt32)
    // mutating
    case writeMemory(address: UInt32, bytes: [UInt8])
    case eraseFlash(code: UInt16)
    case writeFlash(address: UInt32, bytes: [UInt8])
    case reboot            // WRITE_TO_MEMORY 0x2000FC <- F5 00 00 00 (fwupd restart)

    public var isMutating: Bool {
        switch self {
        case .writeMemory, .eraseFlash, .writeFlash, .reboot: return true
        default: return false
        }
    }

    public var description: String {
        func blob(_ b: [UInt8]) -> String {
            if b.count <= 32 { return hex(b) }
            if b.allSatisfy({ $0 == b[0] }) { return String(format: "%d x %02x", b.count, b[0]) }
            return "\(b.count) bytes sha256 \(Checksum.sha256(b).prefix(16))"
        }
        switch self {
        case .rcEnable: return "RC ENABLE (0x01, PRIUS)"
        case .rcDisable: return "RC DISABLE (0x02)"
        case .sleep(let ms): return "sleep \(ms) ms"
        case .expectActiveBank(let b): return "expect active bank \(b) (RAM 0x20010c)"
        case .expectMemory(let a, let b): return "expect RAM \(h32(a)) == \(blob(b))"
        case .expectFlash(let a, let b): return "expect flash \(h(Int(a))) == \(blob(b))"
        case .expectSum32(let a, let l, let v): return "expect RC 0x11 sum32(\(h(Int(a))), \(h(Int(l)))) == \(h32(v))"
        case .expectCRC16(let a, let l, let v): return "expect RC 0x17 crc16(\(h(Int(a))), \(h(Int(l)))) == \(h32(v))"
        case .writeMemory(let a, let b): return "RC 0x21 WRITE_MEMORY \(h32(a)) <- \(hex(b))"
        case .eraseFlash(let c):
            let r = Panamera.eraseRange(code: c).map { "\(h($0.lowerBound))..<\(h($0.upperBound))" } ?? "INVALID"
            return String(format: "RC 0x14 FLASH_ERASE code %04x (data %02x %02x) clears ", c, c & 0xFF, c >> 8) + r
        case .writeFlash(let a, let b): return "RC 0x20 WRITE_FLASH \(h(Int(a))) <- \(hex(b))"
        case .reboot: return "RC 0x21 WRITE_MEMORY 0x002000fc <- f5000000 (hub restart)"
        }
    }
}

public enum StageKind: String, CaseIterable {
    case preflight, prepare, eraseInactive, verifyErased, writeBody, verifyBody, writeTag, verifyTag,
         invalidateOld, verifyInvalidated, restart
}

public struct FlashStage {
    public let kind: StageKind
    public let ops: [FlashOp]
}

public enum RestartMethod: Equatable {
    /// Disable RC and ask the user to unplug the dock's power (what we recommend: no untested reset path).
    case userPowerCycle
    /// fwupd synaptics-mst restart: write F5 to 0x2000FC (untested on a WD19 over DPCD).
    case rcReboot
}

public struct FlashOptions {
    public var restart: RestartMethod = .userPowerCycle
    /// Also compare RC 0x17 (CRC-16) after writing the body. Off by default: the command is used by
    /// fwupd synaptics-mst on Panamera but never by dell-dock, so it is unproven on this dock.
    public var verifyWithCRC16 = false
    /// fwupd FLASH_SETTLE_TIME.
    public var settleAfterEraseMs = 5000
    public init() {}
}

public enum PlanError: Error, CustomStringConvertible, Equatable {
    case guardsFailed([GuardFailure])
    case invalid(String)
    public var description: String {
        switch self {
        case .guardsFailed(let f): return "refusing: " + f.map { $0.description }.joined(separator: "; ")
        case .invalid(let s): return "invalid plan: \(s)"
        }
    }
}

public struct FlashPlan {
    public let snapshot: DeviceSnapshot
    public let targetDescription: String
    public let targetVersion: [UInt8]
    public let runningBank: Int
    public let targetBank: Int
    public let targetContent: [UInt8]
    public let options: FlashOptions
    public let guards: GuardReport
    public let stages: [FlashStage]

    public var allOps: [FlashOp] { stages.flatMap { $0.ops } }
    public var mutatingOps: [FlashOp] { allOps.filter { $0.isMutating } }

    static let stageOrder: [StageKind] = StageKind.allCases

    /// Structural invariants. Checked by the planner and again by the executor before anything is sent.
    public func validate() throws {
        func fail(_ s: String) -> PlanError { .invalid(s) }
        guard runningBank == 0 || runningBank == 1, targetBank == 1 - runningBank else { throw fail("target bank must be the inactive bank") }
        guard stages.map({ $0.kind }) == FlashPlan.stageOrder else { throw fail("stage order") }
        guard targetContent.count == Panamera.bankSize else { throw fail("target size") }
        let tb = Panamera.bankBase(targetBank)
        let tag = BankTag(Array(targetContent[Panamera.tagOffset...]))
        guard tag.isValid(forBank: targetBank) else { throw fail("target tag \(tag) not valid for bank \(targetBank)") }
        let allowedMemory: [UInt32: Set<[UInt8]>?] = [
            Panamera.regMcuCommand: [[Panamera.mcuCommandStopESM, 0, 0, 0]],
            Panamera.regQuadDisable: nil, Panamera.regHDCP22Disable: nil,
        ]
        var bodyCursor = tb
        for st in stages {
            for op in st.ops {
                switch op {
                case .writeMemory(let a, let b):
                    guard st.kind == .prepare, b.count == 4, let allowed = allowedMemory[a] else { throw fail("memory write \(op) not allowed") }
                    if let set = allowed, !set.contains(b) { throw fail("memory value \(op) not allowed") }
                case .reboot:
                    guard st.kind == .restart, options.restart == .rcReboot else { throw fail("reboot outside restart stage") }
                case .eraseFlash(let c):
                    switch st.kind {
                    case .eraseInactive: guard Panamera.bankEraseCodes(targetBank).contains(c) else { throw fail("erase \(op) outside inactive bank") }
                    case .invalidateOld: guard c == Panamera.tagSectorEraseCode(runningBank) else { throw fail("invalidate erase \(op)") }
                    default: throw fail("erase in stage \(st.kind)")
                    }
                case .writeFlash(let a, let b):
                    let a = Int(a)
                    guard !b.isEmpty, b.count <= 32, a / 32 == (a + b.count - 1) / 32 else { throw fail("write shape \(op)") }
                    guard a >= tb, a + b.count <= tb + Panamera.bankSize else { throw fail("write outside inactive bank \(op)") }
                    guard Array(targetContent[(a - tb)..<(a - tb + b.count)]) == b else { throw fail("write bytes differ from target at \(h(a))") }
                    switch st.kind {
                    case .writeBody:
                        guard a == bodyCursor, a + b.count <= tb + Panamera.tagOffset else { throw fail("body writes not contiguous at \(h(a))") }
                        bodyCursor += b.count
                    case .writeTag:
                        guard a == tb + Panamera.tagOffset, b.count == Panamera.tagSize else { throw fail("tag write shape") }
                    default: throw fail("flash write in stage \(st.kind)")
                    }
                default:
                    guard !op.isMutating else { throw fail("unexpected \(op)") }
                }
            }
        }
        guard bodyCursor == tb + Panamera.tagOffset else { throw fail("body writes cover \(h(tb))..<\(h(bodyCursor)) only") }
        guard stages.first(where: { $0.kind == .writeTag })?.ops.filter({ $0.isMutating }).count == 1 else { throw fail("exactly one tag write") }
        guard stages.first(where: { $0.kind == .invalidateOld })?.ops.filter({ $0.isMutating }).count == 1 else { throw fail("exactly one invalidation erase") }
        guard stages.first(where: { $0.kind == .verifyTag })?.ops.contains(.expectFlash(address: UInt32(tb + Panamera.tagOffset), bytes: tag.bytes)) == true
        else { throw fail("tag not verified before invalidation") }
    }

    public func summary() -> String {
        var s = """
        Flash plan: \(targetDescription)
          device: chip \(String(format: "%04x", snapshot.identity.chipId)) fw \(snapshot.identity.firmwareString), running bank \(runningBank), tags \(snapshot.tags[0]) / \(snapshot.tags[1])
          target: hub \(formatVersion(targetVersion)) into bank \(targetBank) (\(h(Panamera.bankBase(targetBank)))..<\(h(Panamera.bankBase(targetBank) + Panamera.bankSize))), tag \(BankTag(Array(targetContent[Panamera.tagOffset...])))
          ESM: untouched; restart: \(options.restart)
          guards: \(guards.ok ? "all passed" : "FAILED") (\(guards.passed.count) passed, \(guards.failures.count) failed)

        """
        for st in stages {
            let muts = st.ops.filter { $0.isMutating }.count
            s += "  [\(st.kind.rawValue)] \(st.ops.count) ops, \(muts) mutating\n"
            let show = st.ops.count > 8 ? Array(st.ops.prefix(3)) + Array(st.ops.suffix(2)) : st.ops
            for (i, op) in show.enumerated() {
                if st.ops.count > 8 && i == 3 { s += "      ... \(st.ops.count - 5) more\n" }
                s += "      \(op)\n"
            }
        }
        return s
    }
}

public enum FlashPlanner {
    /// Build a plan. Throws `PlanError.guardsFailed` if any guard fails; the plan never executes anything.
    public static func plan(snapshot s: DeviceSnapshot, target: FlashTarget, backup: VerifiedBackup?,
                            power: PowerSourceProvider, options: FlashOptions = FlashOptions()) throws -> FlashPlan {
        let guards = Guards.evaluate(snapshot: s, target: target, backup: backup, power: power)
        guard guards.ok, let backup = backup else { throw PlanError.guardsFailed(guards.failures) }

        let rb = s.activeBank, tbIdx = 1 - rb
        let tb = Panamera.bankBase(tbIdx), rbBase = Panamera.bankBase(rb)
        let content = target.content(forBank: tbIdx)
        let body = Array(content[0..<Panamera.tagOffset])
        let tag = Array(content[Panamera.tagOffset...])
        func u(_ i: Int) -> UInt32 { UInt32(i) }

        let preflight: [FlashOp] = [
            .rcEnable,
            .expectActiveBank(rb),
            .expectMemory(address: Panamera.ramConfig, bytes: Panamera.configSignature),
            .expectMemory(address: Panamera.ramBoardId, bytes: [UInt8(s.boardId >> 8), UInt8(s.boardId & 0xFF)]),
            .expectFlash(address: u(rbBase + Panamera.tagOffset), bytes: s.tags[rb].bytes),
            .expectFlash(address: u(tb + Panamera.tagOffset), bytes: s.tags[tbIdx].bytes),
            .expectSum32(address: u(rbBase), length: u(Panamera.bankSize), value: s.bankSum32[rb]),
            .expectSum32(address: u(Panamera.esmOffset), length: u(Panamera.esmSize), value: s.esmSum32),
            .expectMemory(address: Panamera.regQuadDisable, bytes: s.quadRegister),
            .expectMemory(address: Panamera.regHDCP22Disable, bytes: s.hdcpRegister),
        ]

        // fu_synaptics_mst_device_panamera_prepare_write (values computed from the snapshot so the plan is exact).
        var hdcp = s.hdcpRegister
        hdcp[0] &= ~0x04
        let prepare: [FlashOp] = [
            .writeMemory(address: Panamera.regMcuCommand, bytes: [Panamera.mcuCommandStopESM, 0, 0, 0]),
            .sleep(ms: 1),
            .writeMemory(address: Panamera.regQuadDisable, bytes: [0, 0, 0, 0]),
            .writeMemory(address: Panamera.regHDCP22Disable, bytes: hdcp),
            .expectFlash(address: u(rbBase + Panamera.tagOffset), bytes: s.tags[rb].bytes),  // flash still readable
        ]

        let erase: [FlashOp] = Panamera.bankEraseCodes(tbIdx).map { .eraseFlash(code: $0) } + [.sleep(ms: options.settleAfterEraseMs)]
        let verifyErased: [FlashOp] = [
            .expectSum32(address: u(tb), length: u(Panamera.bankSize), value: Checksum.sum32([UInt8](repeating: 0xFF, count: Panamera.bankSize))),
            .expectFlash(address: u(tb), bytes: [UInt8](repeating: 0xFF, count: Panamera.bankSize)),
        ]

        var writeBody: [FlashOp] = []
        var off = 0
        while off < Panamera.tagOffset {
            let n = min(32, Panamera.tagOffset - off)
            writeBody.append(.writeFlash(address: u(tb + off), bytes: Array(body[off..<(off + n)])))
            off += n
        }
        var verifyBody: [FlashOp] = [
            .expectFlash(address: u(tb), bytes: body),
            .expectSum32(address: u(tb), length: u(Panamera.tagOffset), value: Checksum.sum32(body)),
        ]
        if options.verifyWithCRC16 {
            verifyBody.append(.expectCRC16(address: u(tb), length: u(Panamera.maxCodeSize),
                                           value: UInt32(Checksum.crc16(body[0..<Panamera.maxCodeSize]))))
        }

        let writeTag: [FlashOp] = [.writeFlash(address: u(tb + Panamera.tagOffset), bytes: tag)]
        let verifyTag: [FlashOp] = [
            .expectFlash(address: u(tb + Panamera.tagOffset), bytes: tag),
            .expectSum32(address: u(tb), length: u(Panamera.bankSize), value: Checksum.sum32(content)),
        ]

        let invalidate: [FlashOp] = [
            .expectFlash(address: u(rbBase + Panamera.tagOffset), bytes: s.tags[rb].bytes),
            .eraseFlash(code: Panamera.tagSectorEraseCode(rb)),
        ]
        let keep = backup.bank(rb).prefix(Panamera.tagSectorOffset)
        let verifyInvalidated: [FlashOp] = [
            .expectFlash(address: u(rbBase + Panamera.tagSectorOffset), bytes: [UInt8](repeating: 0xFF, count: 0x1000)),
            .expectSum32(address: u(rbBase), length: u(Panamera.tagSectorOffset), value: Checksum.sum32(keep)),
            .expectFlash(address: u(tb + Panamera.tagOffset), bytes: tag),
        ]
        let restart: [FlashOp] = options.restart == .rcReboot ? [.sleep(ms: 2000), .reboot] : [.rcDisable]

        let plan = FlashPlan(snapshot: s, targetDescription: target.description, targetVersion: target.version,
                             runningBank: rb, targetBank: tbIdx, targetContent: content, options: options, guards: guards,
                             stages: [
                                FlashStage(kind: .preflight, ops: preflight),
                                FlashStage(kind: .prepare, ops: prepare),
                                FlashStage(kind: .eraseInactive, ops: erase),
                                FlashStage(kind: .verifyErased, ops: verifyErased),
                                FlashStage(kind: .writeBody, ops: writeBody),
                                FlashStage(kind: .verifyBody, ops: verifyBody),
                                FlashStage(kind: .writeTag, ops: writeTag),
                                FlashStage(kind: .verifyTag, ops: verifyTag),
                                FlashStage(kind: .invalidateOld, ops: invalidate),
                                FlashStage(kind: .verifyInvalidated, ops: verifyInvalidated),
                                FlashStage(kind: .restart, ops: restart),
                             ])
        try plan.validate()
        return plan
    }
}
