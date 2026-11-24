// SPDX-License-Identifier: LGPL-2.1-or-later
// Dell .cab handling: SHA-256 allow-list, then extraction of vmm5331.bin with /usr/bin/tar
// (macOS bsdtar/libarchive reads Microsoft Cabinet incl. MSZIP). No network access here.

import Foundation

public enum PackageError: Error, CustomStringConvertible, Equatable {
    case unknownPackage(sha256: String)
    case extractionFailed(String)
    case hubImageMismatch(expected: String, got: String)

    public var description: String {
        switch self {
        case .unknownPackage(let s): return "cabinet sha256 \(s) is not a known Dell dock package"
        case .extractionFailed(let s): return "could not extract vmm5331.bin: \(s)"
        case .hubImageMismatch(let e, let g): return "vmm5331.bin sha256 \(g) != expected \(e)"
        }
    }
}

public enum FirmwarePackage {
    public static let hubImageName = "vmm5331.bin"
    static let tarPath = "/usr/bin/tar"

    /// Hashes the file and looks it up. Nothing is extracted from an unknown cabinet.
    public static func verifyCab(at url: URL) throws -> KnownPackage {
        let sha = Checksum.sha256(try Data(contentsOf: url))
        guard let pkg = KnownFirmware.package(cabSHA256: sha) else { throw PackageError.unknownPackage(sha256: sha) }
        return pkg
    }

    /// Verify the cabinet, extract only `vmm5331.bin` into a fresh temporary directory, verify its hash, parse it.
    public static func loadHubImage(fromCab url: URL) throws -> VMMImage {
        let pkg = try verifyCab(at: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twindesk-cab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: tarPath)
        p.arguments = ["-x", "-f", url.path, "-C", dir.path, hubImageName]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw PackageError.extractionFailed("\(error)") }
        p.waitUntilExit()
        let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw PackageError.extractionFailed("tar exit \(p.terminationStatus): \(msg)") }

        let out = dir.appendingPathComponent(hubImageName)
        let data = try Data(contentsOf: out)
        let sha = Checksum.sha256(data)
        guard sha == pkg.hubImageSHA256 else { throw PackageError.hubImageMismatch(expected: pkg.hubImageSHA256, got: sha) }
        return try VMMImage.parse([UInt8](data))
    }
}
