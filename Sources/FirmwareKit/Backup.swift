// SPDX-License-Identifier: LGPL-2.1-or-later
// Full 512 KiB flash backup with a JSON sidecar, verified by a second full read.

import Foundation

public struct BackupRecord: Codable, Equatable {
    public var format = "dockdesk-vmm5331-backup-1"
    public var createdAt: String
    public var firmwareVersion: String       // DPCD 0x50A at backup time
    public var activeBank: Int               // RAM 0x20010C at backup time
    public var chipId: String
    public var boardId: String
    public var size: Int
    public var sha256: String
    public var tags: [String]                // hex of both bank tags
    public var esmSum32: String
    public var verifiedByReread: Bool
    public var binFile: String
}

public struct VerifiedBackup {
    public let url: URL
    public let record: BackupRecord
    public let bytes: [UInt8]
    public let analysis: FlashAnalysis

    public var runningBank: Int { record.activeBank }
    public func bank(_ i: Int) -> ArraySlice<UInt8> { bytes[Panamera.bankBase(i)..<(Panamera.bankBase(i) + Panamera.bankSize)] }
}

public enum BackupError: Error, CustomStringConvertible, Equatable {
    case rereadMismatch(firstDifference: Int)
    case missingSidecar(String)
    case shaMismatch(expected: String, got: String)
    case notVerified
    case malformed(String)

    public var description: String {
        switch self {
        case .rereadMismatch(let o): return "second read differs from first at \(h(o)); flash reads are not stable, backup rejected"
        case .missingSidecar(let p): return "backup sidecar \(p) missing"
        case .shaMismatch(let e, let g): return "backup file sha256 \(g) != sidecar \(e)"
        case .notVerified: return "backup was never verified by a second read"
        case .malformed(let s): return "backup malformed: \(s)"
        }
    }
}

public enum Backup {
    static let readChunk = 4096

    public static func readWholeFlash(_ t: HubTransport, progress: ((Int, Int) -> Void)? = nil) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Panamera.flashSize)
        var addr = 0
        while addr < Panamera.flashSize {
            out += try t.rcReadFlash(UInt32(addr), count: readChunk)
            addr += readChunk
            progress?(addr, Panamera.flashSize)
        }
        return out
    }

    public static func sidecarURL(for bin: URL) -> URL { bin.appendingPathExtension("json") }

    /// Read the flash twice, require identical results, then write `<dir>/vmm5331-<version>-<date>.bin` + `.json`.
    public static func create(transport t: HubTransport, directory: URL, now: Date = Date(),
                              progress: ((Int, Int) -> Void)? = nil) throws -> VerifiedBackup {
        let id = try DeviceReader.identity(t)
        try t.rcEnable()
        defer { try? t.rcDisable() }
        let status = try t.readU32LE(memory: Panamera.regBootStatus)
        let first = try readWholeFlash(t, progress: progress)
        let second = try readWholeFlash(t, progress: progress)
        if let d = zip(first, second).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            throw BackupError.rereadMismatch(firstDifference: d)
        }
        let a = try FlashAnalysis(first)
        let iso = ISO8601DateFormatter()
        let stamp = iso.string(from: now)
        let safeStamp = stamp.replacingOccurrences(of: ":", with: "")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bin = directory.appendingPathComponent("vmm5331-\(id.firmwareString)-\(safeStamp).bin")
        let partial = bin.appendingPathExtension("partial")
        try Data(first).write(to: partial, options: .atomic)
        if FileManager.default.fileExists(atPath: bin.path) { try FileManager.default.removeItem(at: bin) }
        try FileManager.default.moveItem(at: partial, to: bin)
        let rec = BackupRecord(createdAt: stamp, firmwareVersion: id.firmwareString,
                               activeBank: DeviceSnapshot.activeBank(fromBootStatus: status),
                               chipId: String(format: "0x%04x", id.chipId),
                               boardId: "", size: first.count, sha256: a.sha256,
                               tags: a.banks.map { $0.tag.description }, esmSum32: h32(a.esmSum32),
                               verifiedByReread: true, binFile: bin.lastPathComponent)
        var r = rec
        r.boardId = String(format: "0x%04x", a.banks[r.activeBank].boardId)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(r).write(to: sidecarURL(for: bin), options: .atomic)
        return try load(bin)
    }

    /// Load a backup and check it against its sidecar.
    public static func load(_ bin: URL) throws -> VerifiedBackup {
        let side = sidecarURL(for: bin)
        guard FileManager.default.fileExists(atPath: side.path) else { throw BackupError.missingSidecar(side.path) }
        let rec = try JSONDecoder().decode(BackupRecord.self, from: Data(contentsOf: side))
        let bytes = [UInt8](try Data(contentsOf: bin))
        guard bytes.count == Panamera.flashSize, rec.size == bytes.count else { throw BackupError.malformed("size \(bytes.count)") }
        let sha = Checksum.sha256(bytes)
        guard sha == rec.sha256 else { throw BackupError.shaMismatch(expected: rec.sha256, got: sha) }
        guard rec.verifiedByReread else { throw BackupError.notVerified }
        guard rec.activeBank == 0 || rec.activeBank == 1 else { throw BackupError.malformed("active bank \(rec.activeBank)") }
        return VerifiedBackup(url: bin, record: rec, bytes: bytes, analysis: try FlashAnalysis(bytes))
    }
}
