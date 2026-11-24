import AppKit
import CoreGraphics
import DockKit

/// Twin mode: two virtual 1080p monitors composited side by side onto the
/// physical wide display that the dock's hub splits across two real monitors.
@MainActor
public final class TwinSession {
    public enum TwinError: Error, CustomStringConvertible {
        case noPhysicalDisplay, virtualDisplayFailed
        public var description: String {
            switch self {
            case .noPhysicalDisplay: return "the dock's wide display was not found"
            case .virtualDisplayFailed: return "macOS refused to create a virtual display"
            }
        }
    }

    public var swapped = false { didSet { layout() } }
    public var log: (String) -> Void = { _ in }

    private var left: VirtualScreen?
    private var right: VirtualScreen?
    private var mirrors: [Mirror] = []
    private var window: NSWindow?
    private var overlaySpace: OverlaySpace?
    private var guardTimer: Timer?
    private var physical: CGDirectDisplayID = 0
    private let w: Int, h: Int, fps: Int

    public init(tileWidth: Int = 1920, tileHeight: Int = 1080, fps: Int = 60) {
        w = tileWidth; h = tileHeight; self.fps = fps
    }

    public func start() async throws {
        guard let phys = Dock.externalDisplay() else { throw TwinError.noPhysicalDisplay }
        physical = phys
        let origin = CGDisplayBounds(phys).origin

        guard let l = VirtualScreen(name: "TwinDesk Left", serial: 1, width: w, height: h, hz: Double(fps)),
              let r = VirtualScreen(name: "TwinDesk Right", serial: 2, width: w, height: h, hz: Double(fps)) else { throw TwinError.virtualDisplayFailed }
        left = l; right = r
        log("virtual displays \(l.id) and \(r.id) created")
        try await Task.sleep(nanoseconds: 1_500_000_000) // let WindowServer register them

        arrange(origin: origin)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        makeWindow()
        for screen in [l, r] {
            let m = Mirror()
            m.onStop = { [weak self] e in Task { @MainActor in self?.log("capture stopped: \(e.localizedDescription)") } }
            try await m.start(displayID: screen.id, width: w, height: h, fps: fps)
            mirrors.append(m)
        }
        layout()
        startPointerGuard()
        log("twin mode running")
    }

    public func stop() {
        guardTimer?.invalidate(); guardTimer = nil
        mirrors.forEach { $0.stop() }
        mirrors = []
        overlaySpace = nil
        window?.orderOut(nil); window = nil
        left = nil; right = nil // releasing the objects removes the virtual displays
    }

    public var frameCounts: [Int] { mirrors.map(\.frames) }

    /// False once the physical display went away (dock unplugged, sleep): the session must be rebuilt.
    public var isHealthy: Bool { physical != 0 && CGDisplayIsOnline(physical) != 0 && mirrors.count == 2 }

    /// Left and right virtual screens side by side where the wide display was;
    /// the physical display is parked touching only the bottom-right corner.
    private func arrange(origin: CGPoint) {
        guard let l = left, let r = right else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        let x = Int32(origin.x), y = Int32(origin.y)
        CGConfigureDisplayOrigin(cfg, l.id, x, y)
        CGConfigureDisplayOrigin(cfg, r.id, x + Int32(w), y)
        CGConfigureDisplayOrigin(cfg, physical, x + Int32(2 * w), y + Int32(h))
        let e = CGCompleteDisplayConfiguration(cfg, .forSession)
        log("arrangement applied (\(e.rawValue))")
    }

    private func makeWindow() {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == physical }) else { return }
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        win.isOpaque = true
        win.backgroundColor = .black
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        win.contentView = view
        win.setFrame(screen.frame, display: true)
        win.orderFrontRegardless()
        window = win
        // Keep the picture up during Mission Control and App Exposé animations.
        overlaySpace = OverlaySpace(window: win)
        log(overlaySpace == nil ? "overlay space unavailable, using a normal window" : "output window placed above all spaces")
    }

    private func layout() {
        guard let root = window?.contentView?.layer, mirrors.count == 2 else { return }
        let half = root.bounds.width / 2
        for (i, m) in mirrors.enumerated() {
            let onLeft = (i == 0) != swapped
            m.layer.frame = CGRect(x: onLeft ? 0 : half, y: 0, width: half, height: root.bounds.height)
            m.layer.contentsGravity = .resize
            m.layer.magnificationFilter = .nearest
            if m.layer.superlayer == nil { root.addSublayer(m.layer) }
        }
    }

    /// The physical display is still part of the desktop; keep the pointer off it.
    private func startPointerGuard() {
        guardTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let r = self.right, let loc = CGEvent(source: nil)?.location else { return }
                let pb = CGDisplayBounds(self.physical)
                guard pb.contains(loc) else { return }
                let rb = CGDisplayBounds(r.id)
                CGWarpMouseCursorPosition(CGPoint(x: rb.maxX - 2, y: rb.maxY - 2))
            }
        }
    }
}
