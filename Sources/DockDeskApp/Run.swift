import AppKit

/// Entry point of the app. Exported with a C name so the development
/// launcher can load this library and start it (see scripts/build-app.sh).
@_cdecl("dockdesk_main")
public func dockdeskMain() {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
