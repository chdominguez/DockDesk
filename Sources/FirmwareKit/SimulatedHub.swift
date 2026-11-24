// SPDX-License-Identifier: LGPL-2.1-or-later
// In-memory model of a VMM5331 behind the RC protocol, for offline tests and dry-run demos.
// Models: 512 KiB NOR flash (erase -> 0xFF, program can only clear bits), tag-based bank selection
// at "power on", RC session gating, sum32/crc16 commands, RAM mirrors of the config block and the
// boot status register, hub restart, and power loss after N mutating commands (optionally torn).

import Foundation

public final class SimulatedHub: HubTransport {
    public struct PowerLoss: Error {}

    /// What the boot ROM does when both tags are valid. Unknown on real hardware (assumption A3),
    /// so tests run with both values.
    public enum BothValidPolicy { case preferBank0, preferBank1 }

    public var flash: [UInt8]
    public var chipId: UInt16
    public var oui: [UInt8]
    public var rcCapable = true
    public var bothValidPolicy: BothValidPolicy
    /// If set, the Nth mutating command (0-based) loses power; with `tornLastOp` it is half applied.
    public var powerFailAtMutation: Int?
    public var tornLastOp = false
    /// Flash addresses whose programmed value gets bit 0 flipped (simulated bad write).
    public var corruptWritesAt: Set<Int> = []
    /// Called after every applied mutating command.
    public var onMutation: ((SimulatedHub) -> Void)?

    public private(set) var runningBank: Int?
    public private(set) var poweredOn = true
    public private(set) var rcEnabled = false
    public private(set) var mutationCount = 0
    /// Programming that would need a 0 -> 1 transition (i.e. writes to non-erased bytes).
    public private(set) var programViolations = 0
    /// Erase codes that touched the bank that was running when they were issued.
    public private(set) var runningBankErases: [UInt16] = []
    public private(set) var commandLog: [String] = []
    public private(set) var ram: [UInt32: [UInt8]] = [:]
    var configRAMOverride: [UInt8]?
    var boardIdRAMOverride: [UInt8]?

    public init(flash: [UInt8], chipId: UInt16 = Panamera.chipId, oui: [UInt8] = Panamera.synapticsOUI,
                bothValidPolicy: BothValidPolicy = .preferBank0) {
        precondition(flash.count == Panamera.flashSize)
        self.flash = flash
        self.chipId = chipId
        self.oui = oui
        self.bothValidPolicy = bothValidPolicy
        powerOn()
    }

    public func overrideConfigSignature(_ b: [UInt8]) { configRAMOverride = b }
    public func overrideBoardId(_ b: [UInt8]) { boardIdRAMOverride = b }

    // MARK: Boot model

    public func tag(_ bank: Int) -> BankTag {
        BankTag(Array(flash[(Panamera.bankBase(bank) + Panamera.tagOffset)..<(Panamera.bankBase(bank) + Panamera.bankSize)]))
    }
    /// Banks the boot ROM might pick (valid tag). Empty means we assume it does not boot (conservative).
    public var bootCandidates: [Int] { (0..<2).filter { tag($0).isValid(forBank: $0) } }

    public func powerOn() {
        poweredOn = true
        rcEnabled = false
        let c = bootCandidates
        switch c.count {
        case 0: runningBank = nil
        case 1: runningBank = c[0]
        default: runningBank = bothValidPolicy == .preferBank0 ? 0 : 1
        }
        ram = [Panamera.regQuadDisable: [0x01, 0, 0, 0], Panamera.regHDCP22Disable: [0x04, 0, 0, 0]]
    }

    /// Power cycle (also clears a pending power-fail injection).
    public func powerCycle() {
        powerFailAtMutation = nil
        tornLastOp = false
        powerOn()
    }

    /// Body (0..<0x1FFF0) of `bank`.
    public func body(_ bank: Int) -> ArraySlice<UInt8> { flash[Panamera.bankBase(bank)..<(Panamera.bankBase(bank) + Panamera.tagOffset)] }

    // MARK: HubTransport

    private func alive() throws {
        guard poweredOn, let _ = runningBank else { throw HubTransportError.notConnected }
    }
    private func rcOn() throws {
        try alive()
        guard rcEnabled else { throw HubTransportError.rcNotEnabled }
    }
    private var running: ArraySlice<UInt8> {
        let b = Panamera.bankBase(runningBank ?? 0)
        return flash[b..<(b + Panamera.bankSize)]
    }

    public func dpcdRead(_ address: UInt32, count: Int) throws -> [UInt8] {
        try alive()
        var dpcd = [UInt8](repeating: 0, count: 0x600)
        dpcd[Int(Panamera.dpcdRCCapability)] = rcCapable ? 0x04 : 0
        let o = Int(Panamera.dpcdBranchOUI)
        dpcd[o..<o + 3] = ArraySlice(oui)
        dpcd[o + 3..<o + 7] = ArraySlice(Panamera.deviceIdPrefix)
        dpcd[o + 7] = UInt8(chipId >> 8); dpcd[o + 8] = UInt8(chipId & 0xFF)
        let v = running.startIndex + Panamera.versionOffset
        dpcd[o + 10..<o + 13] = flash[v..<v + 3]
        let a = Int(address)
        guard a + count <= dpcd.count else { throw HubTransportError.outOfRange("dpcd \(address)") }
        return Array(dpcd[a..<a + count])
    }

    public func rcEnable() throws { try alive(); rcEnabled = true; commandLog.append("ENABLE_RC") }
    public func rcDisable() throws { try alive(); rcEnabled = false; commandLog.append("DISABLE_RC") }

    public func rcReadMemory(_ address: UInt32, count: Int) throws -> [UInt8] {
        try rcOn()
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = memoryByte(address + UInt32(i)) }
        return out
    }

    private func memoryByte(_ a: UInt32) -> UInt8 {
        if a >= Panamera.ramConfig && a < Panamera.ramConfig + 0x100 {
            let off = Int(a - Panamera.ramConfig)
            if off < 4, let o = configRAMOverride { return o[off] }
            if (0xE...0xF).contains(off), let o = boardIdRAMOverride { return o[off - 0xE] }
            return running[running.startIndex + Panamera.configOffset + off]
        }
        if a >= Panamera.regBootStatus && a < Panamera.regBootStatus + 4 {
            let v: UInt32 = runningBank == 1 ? 1 << 7 : 0     // assumption A2: bit 7 set when running bank 1
            return UInt8((v >> (8 * (a - Panamera.regBootStatus))) & 0xFF)
        }
        for (base, bytes) in ram where a >= base && a < base + UInt32(bytes.count) { return bytes[Int(a - base)] }
        return 0
    }

    private func checkFlashRange(_ address: UInt32, _ count: Int) throws -> Range<Int> {
        let a = Int(address)
        guard count >= 0, a + count <= Panamera.flashSize else { throw HubTransportError.outOfRange("flash \(h(a)) + \(count)") }
        return a..<(a + count)
    }

    public func rcReadFlash(_ address: UInt32, count: Int) throws -> [UInt8] {
        try rcOn()
        return Array(flash[try checkFlashRange(address, count)])
    }

    public func rcFlashSum32(_ address: UInt32, length: UInt32) throws -> UInt32 {
        try rcOn()
        return Checksum.sum32(flash[try checkFlashRange(address, Int(length))])
    }

    public func rcFlashCRC16(_ address: UInt32, length: UInt32) throws -> UInt32 {
        try rcOn()
        return UInt32(Checksum.crc16(flash[try checkFlashRange(address, Int(length))]))
    }

    /// Common gate for mutating commands: power-fail injection, counting, observer.
    private func mutate(_ name: String, _ apply: (_ torn: Bool) throws -> Void) throws {
        try rcOn()
        if let n = powerFailAtMutation, mutationCount == n {
            if tornLastOp { try apply(true) }
            poweredOn = false
            commandLog.append("POWER LOSS during \(name)\(tornLastOp ? " (torn)" : "")")
            throw PowerLoss()
        }
        try apply(false)
        mutationCount += 1
        commandLog.append(name)
        onMutation?(self)
    }

    public func rcWriteMemory(_ address: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws {
        try mutate("WRITE_MEMORY \(h32(address)) \(hex(bytes))") { torn in
            if torn { return }
            if address == Panamera.regMcuCommand && bytes.first == Panamera.mcuCommandReboot {
                powerOn()          // restart: boot ROM re-selects the bank
                return
            }
            ram[address] = bytes
        }
    }

    public func rcEraseFlash(code: UInt16, _ auth: WriteAuthorization) throws {
        guard let r = Panamera.eraseRange(code: code) else { throw HubTransportError.rcFailed(command: Panamera.RC.flashErase.rawValue, code: 1) }
        try mutate(String(format: "FLASH_ERASE %04x", code)) { torn in
            if let rb = runningBank, r.overlaps(Panamera.bankBase(rb)..<(Panamera.bankBase(rb) + Panamera.bankSize)) {
                runningBankErases.append(code)
            }
            let end = torn ? r.lowerBound + r.count / 2 : r.upperBound
            for i in r.lowerBound..<end { flash[i] = 0xFF }
        }
    }

    public func rcWriteFlash(_ address: UInt32, bytes: [UInt8], _ auth: WriteAuthorization) throws {
        let r = try checkFlashRange(address, bytes.count)
        guard bytes.count <= 32, r.lowerBound / 32 == (r.upperBound - 1) / 32 else {
            throw HubTransportError.rcFailed(command: Panamera.RC.writeFlash.rawValue, code: 1)
        }
        try mutate("WRITE_FLASH \(h(r.lowerBound)) \(bytes.count)") { torn in
            let n = torn ? bytes.count / 2 : bytes.count
            for (i, b) in bytes.prefix(n).enumerated() {
                let a = r.lowerBound + i
                var v = b
                if corruptWritesAt.contains(a) { v ^= 0x01 }
                if flash[a] & v != v { programViolations += 1 }
                flash[a] &= v            // NOR: programming can only clear bits
            }
        }
    }

    public func sleep(milliseconds: Int) {}

    // MARK: Test helpers

    /// sha256 of the part of `bank` that can hold code (0..<0x1F000; the last 4 KiB is padding + tag).
    public func codeHash(_ bank: Int) -> String {
        Checksum.sha256(Data(flash[Panamera.bankBase(bank)..<(Panamera.bankBase(bank) + Panamera.tagSectorOffset)]))
    }

    /// True if every bank the ROM might boot holds intact code from `intactCode` (see `codeHash`).
    /// Policy-independent: with two valid tags both must be intact because we do not know which wins.
    public func isBootable(intactCode: Set<String>) -> Bool {
        let c = bootCandidates
        return !c.isEmpty && c.allSatisfy { intactCode.contains(codeHash($0)) }
    }
}
