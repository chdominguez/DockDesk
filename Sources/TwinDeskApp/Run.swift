import AppKit

/// Entry point of the app. Exported with a C name so the development
/// launcher can load this library and start it (see scripts/build-app.sh).
@_cdecl("twindesk_main")
public func twindeskMain() {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
