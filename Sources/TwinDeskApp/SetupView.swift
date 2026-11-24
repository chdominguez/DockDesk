import DockKit
import FirmwareKit
import SwiftUI

/// Setup window: what TwinDesk found, how it works, and hub firmware management.
struct SetupView: View {
    let state: DockState
    let info: DockInfo?
    @ObservedObject var firmware: FirmwareController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if let icon = NSApp.applicationIconImage { Image(nsImage: icon).resizable().frame(width: 52, height: 52) }
                    VStack(alignment: .leading) {
                        Text("TwinDesk").font(.largeTitle).bold()
                        Text("Two monitors from one cable on a Dell WD19 dock.").foregroundStyle(.secondary)
                    }
                }
                Divider()
                status
                Divider()
                firmwareSection
                Divider()
                Text("How it works").font(.headline)
                step("1", "The dock's video hub can cut one wide picture in two, one half per monitor. TwinDesk switches that on.")
                step("2", "After every dock reconnect, replug one monitor's cable at the dock once so the hub offers the wide display.")
                step("3", "Wide gives one desktop across both monitors. Twin adds two virtual monitors on top so macOS treats them as separate desktops. Twin needs Screen Recording permission.")
                Divider()
                Text("Good to know").font(.headline)
                Text("• Each monitor runs at 1920×1080, 60 Hz.\n• Twin mode adds a frame or two of delay and shows copy-protected video as black.\n• The hub setting is temporary; unplugging the dock resets it.\n• TwinDesk uses private macOS interfaces and may break with a system update.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(item: $firmware.pendingInstall) { pkg in
            Alert(title: Text("Install hub firmware \(pkg.hubVersionString)?"),
                  message: Text("TwinDesk will download Dell's package \(pkg.fileName), back up the current firmware, write the new one to the dock's spare slot, verify it and restart the video hub. It takes about seven minutes and the external screens go dark briefly.\n\nKeep the dock plugged in and powered the whole time. An interrupted or failed write can leave the dock without video. This has been tested on one WD19S only."),
                  primaryButton: .destructive(Text("Install")) { firmware.install(pkg) },
                  secondaryButton: .cancel())
        }
    }

    // MARK: sections

    @ViewBuilder private var status: some View {
        switch state {
        case .noDock:
            banner("No dock detected", "Connect the dock to the Mac with both monitors on its DisplayPort sockets.", .secondary)
        case .unsupported(let why):
            banner("This dock is not supported", "TwinDesk needs a Dell WD19-family dock with a Synaptics VMM5331 hub. Found: \(why).", .orange)
        case .ready(let v):
            banner("Ready", "Hub firmware \(v) has the split feature. Choose Twin or Wide from the menu bar icon.", .green)
        case .firmwareTooNew(let v):
            banner("Hub firmware \(v) is too new", "Dell removed the split feature after hub firmware 05.07.04. Install 05.07.04 below to use TwinDesk.", .orange)
        }
    }

    @ViewBuilder private var firmwareSection: some View {
        let supported: Bool = { switch state { case .ready, .firmwareTooNew: return true; default: return false } }()
        VStack(alignment: .leading, spacing: 10) {
            Text("Hub firmware").font(.headline)
            if let info, supported {
                Text("Installed: \(info.firmware)").monospacedDigit()
            }
            switch firmware.phase {
            case .working:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: firmware.fraction)
                    HStack {
                        Text(firmware.step)
                        Spacer()
                        Text("\(Int(firmware.fraction * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    if !firmware.detail.isEmpty { Text(firmware.detail).font(.callout).foregroundStyle(.secondary) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))
            case .succeeded(let msg):
                result(msg, ok: true)
            case .failed(let msg):
                result(msg, ok: false)
            case .idle:
                EmptyView()
            }
            if !firmware.isWorking {
                let split = KnownFirmware.viewXpandPackage, latest = KnownFirmware.latestPackage
                HStack {
                    Button("Install \(split.hubVersionString) (enables split)") { firmware.pendingInstall = split }
                        .disabled(!supported || info?.firmware == split.hubVersionString)
                    Button("Install Dell's \(latest.hubVersionString)") { firmware.pendingInstall = latest }
                        .disabled(!supported || info?.firmware == latest.hubVersionString)
                }
                HStack {
                    Button("Back up now") { firmware.backup() }.disabled(!supported)
                    Button("Show backups") { firmware.revealBackups() }
                }
                Text("Only the video hub is changed, never the dock's controller or USB hubs. A backup is always taken first. Firmware comes from Dell's packages on LVFS and is checked against known SHA-256 values before use.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func result(_ msg: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? .green : .orange)
            Text(msg).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func banner(_ title: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).bold().frame(width: 18)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension KnownPackage: Identifiable { public var id: String { cabSHA256 } }
