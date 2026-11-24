import AppKit
import DockKit
import SwiftUI
import TwinKit

enum DisplayMode: String { case mirror = "Mirror", wide = "Wide", twin = "Twin" }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let dockQueue = DockQueue.shared
    private let firmware = FirmwareController()
    private var info: DockInfo?
    private var state: DockState = .noDock
    private var mode: DisplayMode = .mirror
    private var twin: TwinSession?
    private let hud = BusyHUD()
    private var busy: String? {
        didSet {
            if let busy { hud.show(busy) } else { hud.hide() }
            showMenuBarSpinner(busy != nil)
        }
    }
    private var setupWindow: NSWindow?
    private var swapped = UserDefaults.standard.bool(forKey: "swapSides")

    /// The mode the user last chose; DockDesk returns to it when the dock comes back.
    private var desired: DisplayMode {
        get { DisplayMode(rawValue: UserDefaults.standard.string(forKey: "desiredMode") ?? "") ?? .mirror }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "desiredMode") }
    }
    private var autoReconnect: Bool {
        get { UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoReconnect") }
    }
    private var autoFailed = false          // stop retrying until the displays change again
    private var quietUntil = Date.distantPast // ignore display events caused by our own switching
    private var pendingCheck: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "DockDesk")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.checkAttachment() } }
        firmware.willStart = { [weak self] in
            guard let self else { return }
            self.twin?.stop(); self.twin = nil
            self.quietUntil = .distantFuture
        }
        firmware.didFinish = { [weak self] in
            guard let self else { return }
            self.quietUntil = Date().addingTimeInterval(8)
            self.refreshSetupWindow()
        }
        observeDisplays()
        if CommandLine.arguments.contains("--twin") { select(.twin) }
        else if !UserDefaults.standard.bool(forKey: "setupShown") { UserDefaults.standard.set(true, forKey: "setupShown"); showSetup() }
    }

    func applicationWillTerminate(_ n: Notification) { twin?.stop() }

    // MARK: automatic re-attach

    /// Display added/removed/reconfigured, or the Mac woke up: re-check shortly afterwards.
    private func observeDisplays() {
        let me = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ctx in
            guard !flags.contains(.beginConfigurationFlag), let ctx else { return }
            let app = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { app.displaysChanged() } }
        }, me)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged(force: true) }
        }
    }

    private func displaysChanged(force: Bool = false) {
        guard force || Date() > quietUntil else { return }
        autoFailed = false
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkAttachment() } }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work) // let the link settle
    }

    /// Compare what is running with what the user wants and repair it.
    private func checkAttachment() {
        guard busy == nil, !firmware.isWorking else { return }
        refresh { [weak self] in
            guard let self, self.busy == nil else { return }
            // Twin session whose physical display vanished: tear it down so no orphan virtual monitors remain.
            if let t = self.twin, !t.isHealthy {
                t.stop(); self.twin = nil
                self.mode = .mirror
                self.quietUntil = Date().addingTimeInterval(4)
            }
            guard self.autoReconnect, !self.autoFailed, case .ready = self.state, let info = self.info else { return }
            let want = self.desired
            let ok: Bool
            switch want {
            case .mirror: ok = !info.isSplitting // a hub that starts in split mode may come back wide
            case .wide: ok = info.isSplitting && self.twin == nil
            case .twin: ok = info.isSplitting && self.twin != nil
            }
            if !ok { self.select(want, automatic: true) }
        }
    }

    /// While busy, the menu bar icon is replaced by a small spinner.
    private var menuSpinner: NSProgressIndicator?
    private func showMenuBarSpinner(_ on: Bool) {
        guard let button = item?.button else { return }
        if on {
            if menuSpinner == nil {
                let s = NSProgressIndicator()
                s.style = .spinning
                s.controlSize = .small
                s.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(s)
                NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: button.centerXAnchor), s.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
                menuSpinner = s
            }
            button.image = NSImage(size: NSSize(width: 18, height: 18)) // keep the slot width, hide the glyph
            menuSpinner?.isHidden = false
            menuSpinner?.startAnimation(nil)
        } else {
            menuSpinner?.stopAnimation(nil)
            menuSpinner?.isHidden = true
            button.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "DockDesk")
        }
    }

    // MARK: dock state

    private func refresh(then done: (() -> Void)? = nil) {
        guard !firmware.isWorking else { return }
        dockQueue.async {
            let i = try? Dock.info()
            DispatchQueue.main.async {
                self.info = i
                self.state = i?.state ?? .noDock
                if self.twin == nil, let i { self.mode = i.isSplitting ? .wide : .mirror }
                done?()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func line(_ t: String) { let m = NSMenuItem(title: t, action: nil, keyEquivalent: ""); m.isEnabled = false; menu.addItem(m) }
        switch state {
        case .noDock: line("No dock detected")
        case .unsupported(let why): line("Unsupported dock: \(why)")
        case .firmwareTooNew(let v): line("Hub firmware \(v): split feature removed")
        case .ready(let v): line("Dell dock ready (hub firmware \(v))")
        }
        if let busy { line(busy) }
        menu.addItem(.separator())
        let ready: Bool = { if case .ready = state { return true }; return false }()
        for (m, hint) in [(DisplayMode.twin, "two separate desktops"), (.wide, "one wide desktop"), (.mirror, "same picture on both")] {
            let mi = NSMenuItem(title: "\(m.rawValue): \(hint)", action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = m == mode ? .on : .off
            mi.isEnabled = ready && busy == nil
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let swap = NSMenuItem(title: "Swap left and right", action: #selector(toggleSwap), keyEquivalent: "")
        swap.target = self
        swap.state = swapped ? .on : .off
        swap.isEnabled = twin != nil
        menu.addItem(swap)
        let auto = NSMenuItem(title: "Restore mode when the dock reconnects", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoReconnect ? .on : .off
        menu.addItem(auto)
        let setup = NSMenuItem(title: "Setup and firmware…", action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DockDesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        refresh()
    }

    // MARK: actions

    @objc private func pick(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = DisplayMode(rawValue: raw) { select(m) }
    }

    @objc private func toggleSwap() {
        swapped.toggle()
        UserDefaults.standard.set(swapped, forKey: "swapSides")
        twin?.swapped = swapped
    }

    @objc private func toggleAuto() { autoReconnect.toggle(); if autoReconnect { displaysChanged(force: true) } }
    @objc private func openSetup() { showSetup() }

    private func select(_ target: DisplayMode, automatic: Bool = false) {
        guard busy == nil, !firmware.isWorking else { return }
        if !automatic { desired = target; autoFailed = false }
        Task { @MainActor in
            quietUntil = .distantFuture
            defer { quietUntil = Date().addingTimeInterval(6) }
            do {
                twin?.stop(); twin = nil
                switch target {
                case .mirror:
                    busy = "Switching to Mirror…"
                    try await onDock { try? Dock.setNativeMode(width: 1920, height: 1080); try Dock.setSplit(false) }
                case .wide:
                    try await enterWide(automatic: automatic)
                case .twin:
                    guard CGPreflightScreenCaptureAccess() || (!automatic && CGRequestScreenCaptureAccess()) else {
                        if automatic { autoFailed = true; busy = nil; return }
                        alert("Screen Recording permission needed", "Twin mode copies two virtual desktops onto your monitors. Allow DockDesk under System Settings > Privacy & Security > Screen & System Audio Recording, then choose Twin again.")
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        busy = nil
                        return
                    }
                    try await enterWide(automatic: automatic)
                    busy = "Starting Twin…"
                    let s = TwinSession()
                    s.swapped = swapped
                    s.log = { NSLog("DockDesk: %@", $0) }
                    try await s.start()
                    twin = s
                }
                mode = target
            } catch {
                twin?.stop(); twin = nil
                if automatic { autoFailed = true; NSLog("DockDesk: automatic %@ failed: %@", target.rawValue, "\(error)") }
                else { alert("Could not switch to \(target.rawValue)", "\(error)") }
            }
            busy = nil
            refresh()
        }
    }

    /// Hub split mode on, wait for the wide timing, 3840x1080. The hub only offers the wide timing after it
    /// re-detects a monitor (unless its firmware boots in split mode): DockDesk switches one monitor off over
    /// DDC and the user presses its power button, or replugs a cable if that is not possible.
    private func enterWide(automatic: Bool = false) async throws {
        busy = "Switching to Wide…"
        try await onDock { try Dock.setSplit(true) }
        var i = try await onDock { try Dock.info() }
        if !i.offersWideTiming {
            busy = "Re-detecting monitors…"
            var soft = false
            if (try? await onDock({ try Dock.softUnplug() })) != nil {
                for _ in 0..<8 where !soft {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let now = try? await onDock({ try Dock.info() }), now.monitors < i.monitors { soft = true }
                }
            }
            if soft {
                busy = "Press the power button of the monitor that turned off"
                if !automatic {
                    alert("Turn the monitor back on", "DockDesk switched one monitor off so the dock detects it again. Press that monitor's power button. DockDesk continues automatically.")
                }
            } else {
                busy = "Replug one monitor cable at the dock to finish"
                if !automatic {
                    alert("Replug one monitor", "Unplug one monitor's DisplayPort cable at the dock, wait five seconds and plug it back in. Do not unplug the dock from the Mac. DockDesk continues automatically.")
                }
            }
            for _ in 0..<60 where !i.offersWideTiming {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                i = (try? await onDock { try Dock.info() }) ?? i
            }
            guard i.offersWideTiming else { throw DockError.noWideMode }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        try await onDock { try Dock.setNativeMode(width: Int(i.raw.wide_w), height: Int(i.raw.wide_h), maxHz: 60) }
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private func onDock<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            dockQueue.async { c.resume(with: Result { try work() }) }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        hud.hide()
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
        if let busy { hud.show(busy) }
    }

    private func showSetup() {
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "DockDesk Setup"
            w.isReleasedWhenClosed = false
            w.center()
            setupWindow = w
        }
        firmware.reset()
        refreshSetupWindow()
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    /// Re-read the dock and rebuild the window content (firmware progress lives in `firmware`, so it survives).
    private func refreshSetupWindow() {
        setupWindow?.contentView = NSHostingView(rootView: SetupView(state: state, info: info, firmware: firmware))
        refresh { [weak self] in
            guard let self else { return }
            self.setupWindow?.contentView = NSHostingView(rootView: SetupView(state: self.state, info: self.info, firmware: self.firmware))
        }
    }
}
