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
            guard try Dock.info().offersWideTiming else { fail("split mode set; replug one monitor at the dock, then run this again") }
            try Dock.setNativeMode(width: 3840, height: 1080, maxHz: 60)
        case "mirror":
            try? Dock.setNativeMode(width: 1920, height: 1080)
            try Dock.setSplit(false)
        default: fail("usage: twindeskctl mode wide|mirror")
        }
    } catch { fail("\(error)") }
case "kick":
    // Experiment: toggle the hub's MST enable bit to make it re-run its link/EDID handlers.
    guard let d = td_open() else { fail("no dock") }
    var on: UInt8 = UInt8(args.dropFirst().first ?? "1") ?? 1, off: UInt8 = 0
    print("write 0x111=\(on):", td_dpcd_write(d, 0x111, &on, 1))
    usleep(400_000)
    print("write 0x111=0:", td_dpcd_write(d, 0x111, &off, 1))
    td_close(d)
case "fw":
    firmwareCommand(Array(args.dropFirst()))
case "modes":
    if let d = Dock.externalDisplay() { td_dump_modes(d) } else { fail("no external display") }
case "twin":
    // Runs until interrupted (Ctrl-C) or for N seconds: twindeskctl twin [seconds]
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
    fail("usage: twindeskctl status | mode wide|mirror | twin [seconds]")
}
