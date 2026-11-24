// SPDX-License-Identifier: LGPL-2.1-or-later
// Pre-flight guards. Every one must pass before a plan can be executed with writes enabled.

import Foundation
import IOKit.ps

public protocol PowerSourceProvider {
    /// true = on AC, false = on battery, nil = unknown (treated as a failure).
    func isOnACPower() -> Bool?
}

/// IOKit power-source query (IOPSGetProvidingPowerSourceType). Desktop Macs report "AC Power".
public struct SystemPowerSource: PowerSourceProvider {
    public init() {}
    public func isOnACPower() -> Bool? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return (type as String) == "AC Power"
    }
}

public struct FixedPowerSource: PowerSourceProvider {
    public let value: Bool?
    public init(_ value: Bool?) { self.value = value }
    public func isOnACPower() -> Bool? { value }
}

public enum GuardFailure: Equatable, CustomStringConvertible {
    case wrongOUI([UInt8])
    case wrongDeviceId([UInt8])
    case wrongChip(UInt16)
    case noRemoteControl
    case badConfigSignature([UInt8])
    case wrongBoard(UInt16)
    case targetBoardMismatch(device: UInt16, image: UInt16)
    case runningBankTagInvalid(bank: Int, tag: String)
    case noBackup
    case backupUnverified
    case backupDoesNotMatchDevice(String)
    case runningVersionMismatch(dpcd: String, flash: String)
    case runningBankTagSectorHasCode
    case esmMismatch(device: UInt32, target: UInt32)
    case onBattery
    case powerUnknown

    public var description: String {
        switch self {
        case .wrongOUI(let o): return "branch OUI \(hex(o)) is not Synaptics 90cc24"
        case .wrongDeviceId(let d): return "device id \(hex(d)) does not start with SYNA"
        case .wrongChip(let c): return String(format: "chip id 0x%04x is not 0x5331", c)
        case .noRemoteControl: return "hub does not advertise RC support"
        case .badConfigSignature(let s): return "RAM config signature \(hex(s)) != 20008383"
        case .wrongBoard(let b): return String(format: "board id 0x%04x is not Dell WD19 (0x0103)", b)
        case .targetBoardMismatch(let d, let i): return String(format: "image board id 0x%04x != device 0x%04x", i, d)
        case .runningBankTagInvalid(let b, let t): return "running bank \(b) tag \(t) is not valid; boot selection not understood, refusing"
        case .noBackup: return "no verified backup of this device"
        case .backupUnverified: return "backup not verified by re-read"
        case .backupDoesNotMatchDevice(let s): return "backup does not match the device: \(s)"
        case .runningVersionMismatch(let d, let f): return "DPCD reports \(d) but running bank holds \(f)"
        case .runningBankTagSectorHasCode: return "running bank's last 4 KiB holds code; invalidating it by erase would be unsafe"
        case .esmMismatch(let d, let t): return "ESM region differs (device \(h32(d)), target \(h32(t))); ESM rewrite is not supported"
        case .onBattery: return "Mac is on battery"
        case .powerUnknown: return "cannot determine power source"
        }
    }
}

public struct GuardReport: Equatable {
    public var failures: [GuardFailure] = []
    public var passed: [String] = []
    public var ok: Bool { failures.isEmpty }
}

public enum Guards {
    public static func evaluate(snapshot s: DeviceSnapshot, target: FlashTarget, backup: VerifiedBackup?,
                                power: PowerSourceProvider) -> GuardReport {
        var r = GuardReport()
        func check(_ cond: Bool, _ fail: @autoclosure () -> GuardFailure, _ ok: String) {
            if cond { r.passed.append(ok) } else { r.failures.append(fail()) }
        }
        let id = s.identity
        check(id.oui == Panamera.synapticsOUI, .wrongOUI(id.oui), "OUI 90cc24 (Synaptics)")
        check(Array(id.deviceId.prefix(4)) == Panamera.deviceIdPrefix, .wrongDeviceId(id.deviceId), "device id SYNA..")
        check(id.chipId == Panamera.chipId, .wrongChip(id.chipId), "chip id 0x5331")
        check(id.rcCapable, .noRemoteControl, "RC capability")
        check(s.configSignature == Panamera.configSignature, .badConfigSignature(s.configSignature), "RAM config signature 20008383")
        check(s.boardId == Panamera.dellWD19BoardId, .wrongBoard(s.boardId), "board id 0x0103 (Dell WD19)")
        check(target.boardId == s.boardId, .targetBoardMismatch(device: s.boardId, image: target.boardId), "image board id matches device")
        let rb = s.activeBank
        check(s.tags[rb].isValid(forBank: rb), .runningBankTagInvalid(bank: rb, tag: s.tags[rb].description), "running bank \(rb) tag valid")
        check(s.esmSum32 == target.esmSum32, .esmMismatch(device: s.esmSum32, target: target.esmSum32), "ESM identical, will not be touched")

        if let b = backup {
            check(b.record.verifiedByReread, .backupUnverified, "backup verified by re-read")
            let bi = b.analysis.banks[rb]
            var why: [String] = []
            if b.runningBank != rb { why.append("backup active bank \(b.runningBank) != \(rb)") }
            if bi.tag != s.tags[rb] { why.append("running tag differs") }
            if bi.sum32 != s.bankSum32[rb] { why.append("running bank sum \(h32(s.bankSum32[rb])) != backup \(h32(bi.sum32))") }
            if b.analysis.esmSum32 != s.esmSum32 { why.append("ESM sum differs") }
            check(why.isEmpty, .backupDoesNotMatchDevice(why.joined(separator: ", ")), "backup matches running bank and ESM")
            check(bi.version == id.firmware, .runningVersionMismatch(dpcd: id.firmwareString, flash: formatVersion(bi.version)),
                  "DPCD version == running bank version")
            check(bi.codeEnd <= Panamera.tagSectorOffset && bi.tagSectorPaddingOnly, .runningBankTagSectorHasCode,
                  "running bank's tag sector holds only padding")
        } else {
            r.failures.append(.noBackup)
        }

        switch power.isOnACPower() {
        case .some(true): r.passed.append("Mac on AC power")
        case .some(false): r.failures.append(.onBattery)
        case .none: r.failures.append(.powerUnknown)
        }
        return r
    }
}
