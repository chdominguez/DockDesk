import AppKit
import CDock
import DockKit
import Foundation
import TwinKit

func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "" {
case "status":
    do {
        let i = try Dock.info()
        print("hub:       \(i.chip) (\(String(cString: withUnsafeBytes(of: i.raw.device_id) { Array($0.bindMemory(to: CChar.self)) } + [0])))")
        print("firmware:  \(i.firmware)")
        print("state:     \(i.state)")
        print("monitors:  \(i.monitors)")
        print("hub mode:  \(i.isSplitMode ? "split" : "mirror") (0x\(String(i.raw.mode_byte, radix: 16)))")
        print("wide EDID: \(i.offersWideTiming ? "\(i.raw.wide_w)x\(i.raw.wide_h)" : "no")")
        print("splitting: \(i.isSplitting ? "yes, \(i.raw.upstream_width) -> \(i.raw.port_width) per output" : "no")")
    } catch { fail("\(error)") }
case "mode":
    do {
        switch args.dropFirst().first ?? "" {
        case "wide":
            try Dock.setSplit(true)
            if try !Dock.info().offersWideTiming {
                guard (try? Dock.softUnplug()) != nil else { fail("split mode set; replug one monitor at the dock, then run this again") }
                print("split mode set and one monitor switched off; press its power button")
                var ok = false
                for _ in 0..<60 where !ok { sleep(2); ok = (try? Dock.info().offersWideTiming) ?? false }
                guard ok else { fail("the hub did not offer the wide display; replug one monitor at the dock, then run this again") }
                sleep(3)
            }
            try Dock.setNativeMode(width: 3840, height: 1080, maxHz: 60)
        case "mirror":
            try? Dock.setNativeMode(width: 1920, height: 1080)
            try Dock.setSplit(false)
        default: fail("usage: dockdeskctl mode wide|mirror")
        }
    } catch { fail("\(error)") }
case "kick":
    // Experiment: find a software replacement for replugging a monitor cable.
    //   dockdeskctl kick <mst|mst6|power|none> [--set split|mirror|keep] [--seconds N]
    // Sets the hub mode, applies the method, then reports whether the hub rebuilt its EDID.
    let rest = Array(args.dropFirst())
    func opt(_ flag: String) -> String? { rest.firstIndex(of: flag).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } }
    let method = rest.first ?? ""
    let seconds = Int(opt("--seconds") ?? "") ?? 12
    func snapshot() -> String {
        guard let i = try? Dock.info() else { return "hub not reachable" }
        let macWide = Dock.externalDisplay().map { td_has_native_mode($0, 3840, 1080) } ?? false
        return "mode 0x\(String(i.raw.mode_byte, radix: 16)) monitors \(i.monitors) wideEDID \(i.offersWideTiming ? "yes" : "no") splitting \(i.isSplitting ? "yes" : "no") macOS-3840x1080@1x \(macWide ? "yes" : "no")"
    }
    func write(_ d: OpaquePointer, _ addr: UInt32, _ value: UInt8) {
        var v = value
        print(String(format: "  DPCD 0x%03x <- %02x: %d", addr, value, td_dpcd_write(d, addr, &v, 1)))
    }
    print("before: \(snapshot())")
    do {
        switch opt("--set") ?? "split" {
        case "split": try Dock.setSplit(true)
        case "mirror": try Dock.setSplit(false)
        case "keep": break
        default: fail("--set split|mirror|keep")
        }
    } catch { fail("\(error)") }
    print("mode set: \(snapshot())")
    guard let d = td_open() else { fail("no dock") }
    switch method {
    case "mst": write(d, 0x111, 0x01); usleep(400_000); write(d, 0x111, 0x00)   // MST_EN on, off
    case "mst6": write(d, 0x111, 0x06); usleep(400_000); write(d, 0x111, 0x00)  // sideband only, off
    case "power": write(d, 0x600, 0x02); sleep(1); write(d, 0x600, 0x01)        // hub D3, D0
    case "link": // read-only: list the hub's ports
        print("  sideband on:", td_sb_begin(d))
        var buf = [UInt8](repeating: 0, count: 256)
        let n = td_sb_link_address(d, &buf, 256)
        print("  LINK_ADDRESS: \(n)", n > 0 ? buf.prefix(Int(n)).map { String(format: "%02x", $0) }.joined(separator: " ") : "")
        print("  sideband off:", td_sb_end(d))
    case "phy", "rdpcd": // power one hub output (or the monitor behind it) down and up again
        let port = UInt8(opt("--port") ?? "") ?? 1
        let hold = UInt32(opt("--hold") ?? "") ?? 2
        print("  sideband on:", td_sb_begin(d))
        if method == "phy" {
            print("  POWER_DOWN_PHY port \(port):", td_sb_power_phy(d, port, false)); sleep(hold)
            print("  POWER_UP_PHY port \(port):", td_sb_power_phy(d, port, true))
        } else {
            print("  REMOTE_DPCD_WRITE port \(port) 0x600 <- 02:", td_sb_remote_set_power(d, port, 2)); sleep(hold)
            print("  REMOTE_DPCD_WRITE port \(port) 0x600 <- 01:", td_sb_remote_set_power(d, port, 1))
        }
        usleep(300_000)
        print("  sideband off:", td_sb_end(d))
    case "ddc": // power one monitor down and up again over DDC/CI
        let port = UInt8(opt("--port") ?? "") ?? 1
        let hold = UInt32(opt("--hold") ?? "") ?? 4
        let off = UInt8(opt("--off") ?? "") ?? 4
        print("  sideband on:", td_sb_begin(d))
        print("  DDC power \(off) port \(port):", td_sb_ddc_power(d, port, off))
        for s in 1...hold { sleep(1); print("  +\(s)s while off: \(snapshot())") }
        for attempt in 1...5 {
            let r = td_sb_ddc_power(d, port, 1)
            print("  DDC power 1 port \(port) (attempt \(attempt)):", r)
            if r == 0 { break }
            sleep(1)
        }
        print("  sideband off:", td_sb_end(d))
    case "none": break
    default: fail("usage: dockdeskctl kick mst|mst6|power|link|phy|rdpcd|ddc|none [--set split|mirror|keep] [--port N] [--hold S] [--seconds N]")
    }
    td_close(d)
    var last = ""
    for s in 1...seconds {
        sleep(1)
        let now = snapshot()
        if now != last { print(String(format: "+%2ds: %@", s, now)); last = now }
    }
case "fw":
    firmwareCommand(Array(args.dropFirst()))
case "modes":
    if let d = Dock.externalDisplay() { td_dump_modes(d) } else { fail("no external display") }
case "twin":
    // Runs until interrupted (Ctrl-C) or for N seconds: dockdeskctl twin [seconds]
    MainActor.assumeIsolated {
        let seconds = args.dropFirst().first.flatMap(Double.init)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let session = TwinSession()
        session.log = { print("twin: \($0)"); fflush(stdout) }
        Task { @MainActor in
            do { try await session.start() } catch { session.stop(); fail("twin: \(error)") }
            if let seconds {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                print("twin: frames captured \(session.frameCounts)")
                session.stop()
                exit(0)
            }
        }
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { MainActor.assumeIsolated { session.stop() }; exit(0) }
        src.resume()
        app.run()
    }
default:
    fail("usage: dockdeskctl status | mode wide|mirror | twin [seconds]")
}
