import AppKit
import CDock
import DockKit
import FirmwareKit
import Foundation

/// Runs hub firmware jobs (backup, install) off the main thread and publishes progress for the UI.
@MainActor
final class FirmwareController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case succeeded(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var step = ""
    @Published private(set) var detail = ""
    @Published private(set) var fraction = 0.0
    /// Package awaiting the user's confirmation in the Setup window.
    @Published var pendingInstall: KnownPackage?

    var isWorking: Bool { phase == .working }
    /// Called before a job touches the dock (stop Twin mode, pause polling) and after it finished.
    var willStart: () -> Void = {}
    var didFinish: () -> Void = {}

    nonisolated static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TwinDesk")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    nonisolated static var backupDir: URL { supportDir.appendingPathComponent("Backups") }
    nonisolated static var packageDir: URL { supportDir.appendingPathComponent("Packages") }

    func reset() { if !isWorking { phase = .idle; step = ""; detail = ""; fraction = 0 } }

    // MARK: jobs

    func backup() {
        run { report in
            let b = try Self.withDock { t in try Self.makeBackup(t, report: report, span: 0.0...1.0) }
            return "Backup saved: \(b.url.lastPathComponent)"
        }
    }

    func revealBackups() {
        try? FileManager.default.createDirectory(at: Self.backupDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.backupDir)
    }

    /// Download Dell's package, back up the hub, write the hub firmware, restart the hub, confirm.
    func install(_ pkg: KnownPackage) {
        run { report in
            report("Downloading Dell package", pkg.fileName, 0.0)
            let cab = try Self.fetchPackage(pkg) { f in report("Downloading Dell package", pkg.fileName, 0.05 * f) }
            report("Checking the package", "SHA-256 and firmware image", 0.05)
            let image = try FirmwarePackage.loadHubImage(fromCab: cab)

            let result: String = try Self.withDock { t in
                let backup = try Self.makeBackup(t, report: report, span: 0.06...0.46)
                report("Preparing", "Reading the hub's state", 0.47)
                let snap = try DeviceReader.snapshot(t)
                var opts = FlashOptions()
                opts.restart = .rcReboot
                let plan = try FlashPlanner.plan(snapshot: snap, target: try FlashTarget.dell(image), backup: backup, power: SystemPowerSource(), options: opts)

                // Stage -> progress band inside 0.48...0.95
                let bands: [String: (Double, String)] = [
                    "preflight": (0.48, "Checking the hub"), "prepare": (0.49, "Preparing the hub"),
                    "eraseInactive": (0.50, "Erasing the spare firmware slot"), "verifyErased": (0.55, "Checking the erased slot"),
                    "writeBody": (0.60, "Writing firmware \(pkg.hubVersionString)"), "verifyBody": (0.85, "Verifying what was written"),
                    "writeTag": (0.91, "Marking the new firmware valid"), "verifyTag": (0.92, "Verifying"),
                    "invalidateOld": (0.93, "Retiring the old firmware"), "verifyInvalidated": (0.94, "Verifying"),
                    "restart": (0.95, "Restarting the hub"),
                ]
                let totalWrites = Double(max(plan.mutatingOps.count, 1))
                var sent = 0.0, stage = ""
                t.armForWrites = true
                let exec = FlashExecutor(transport: t) { line in
                    if line.hasPrefix("== stage ") {
                        stage = String(line.dropFirst(9))
                        if let b = bands[stage] { report(b.1, "Do not unplug the dock", b.0) }
                    } else if line.contains("SEND"), stage == "writeBody" {
                        sent += 1
                        if Int(sent) % 32 == 0 { report(bands["writeBody"]!.1, "Do not unplug the dock", 0.60 + 0.25 * min(sent / totalWrites, 1)) }
                    }
                }
                let rep = try exec.execute(plan, allowWrites: true)
                guard rep.completedStages.last == .restart else { throw NSError(domain: "TwinDesk", code: 2, userInfo: [NSLocalizedDescriptionKey: rep.nextStep]) }
                return formatVersion(plan.targetVersion)
            }

            // The hub reboots itself; wait for it to come back and confirm the version.
            var seen = "nothing"
            for i in 0..<30 {
                report("Restarting the hub", "Waiting for the dock to come back", 0.95 + 0.05 * Double(i) / 30)
                Thread.sleep(forTimeInterval: 2)
                if let i = try? Dock.info() { seen = i.firmware; if seen == result { break } }
            }
            guard seen == result else {
                throw NSError(domain: "TwinDesk", code: 3, userInfo: [NSLocalizedDescriptionKey: "The firmware was written and verified, but the hub reports \(seen) instead of \(result). Unplug the dock's power adapter for ten seconds and check again."])
            }
            return "Hub firmware is now \(result)."
        }
    }

    // MARK: plumbing

    private typealias Report = (_ step: String, _ detail: String, _ fraction: Double) -> Void

    private func run(_ job: @escaping (_ report: @escaping Report) throws -> String) {
        guard !isWorking else { return }
        phase = .working; fraction = 0; step = "Starting"; detail = ""
        willStart()
        let report: Report = { s, d, f in
            DispatchQueue.main.async { MainActor.assumeIsolated { self.step = s; self.detail = d; self.fraction = max(self.fraction, min(f, 1)) } }
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Hub firmware operation")
        DockQueue.shared.async {
            let outcome: Phase
            do { outcome = .succeeded(try job(report)) } catch { outcome = .failed("\(error)") }
            ProcessInfo.processInfo.endActivity(activity)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.fraction = 1
                self.phase = outcome
                self.didFinish()
            } }
        }
    }

    private nonisolated static func withDock<T>(_ body: (CDockTransport) throws -> T) throws -> T {
        guard let dock = td_open() else { throw DockError.noDock }
        defer { td_close(dock) }
        return try body(CDockTransport(dock: dock))
    }

    private nonisolated static func makeBackup(_ t: CDockTransport, report: @escaping Report, span: ClosedRange<Double>) throws -> VerifiedBackup {
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        var pass = 0, last = 0
        return try Backup.create(transport: t, directory: backupDir) { done, total in
            if done < last { pass += 1 }
            last = done
            let f = (Double(min(pass, 1)) + Double(done) / Double(max(total, 1))) / 2
            report(pass == 0 ? "Backing up the current firmware" : "Verifying the backup", "Read \(pass + 1) of 2", span.lowerBound + (span.upperBound - span.lowerBound) * min(f, 1))
        }
    }

    /// Returns the local package file, downloading it from Dell's LVFS location if it is not cached.
    /// The content is verified by SHA-256 later (FirmwarePackage.loadHubImage), wherever it came from.
    private nonisolated static func fetchPackage(_ pkg: KnownPackage, progress: @escaping (Double) -> Void) throws -> URL {
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        let dest = packageDir.appendingPathComponent(pkg.fileName)
        if (try? FirmwarePackage.verifyCab(at: dest)) != nil { progress(1); return dest }
        guard let url = URL(string: pkg.url) else { throw URLError(.badURL) }
        let sem = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            defer { sem.signal() }
            if let err { failure = err; return }
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { failure = URLError(.badServerResponse); return }
            do { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: tmp, to: dest) } catch { failure = error }
        }
        let obs = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        task.resume()
        sem.wait()
        obs.invalidate()
        if let failure { throw failure }
        _ = try FirmwarePackage.verifyCab(at: dest)
        return dest
    }
}
