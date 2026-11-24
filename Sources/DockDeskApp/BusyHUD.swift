import AppKit

/// Small floating "working…" panel shown while a mode switch is in progress.
@MainActor
final class BusyHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ text: String) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 76), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) // above the Twin output window
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let bg = NSVisualEffectView(frame: p.contentView!.bounds)
            bg.material = .hudWindow
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 14
            bg.layer?.masksToBounds = true

            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .small
            spin.startAnimation(nil)
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail

            // Spinner and text as one group, centred both ways in the panel.
            let row = NSStackView(views: [spin, label])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(row)
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
                row.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 20),
                row.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -20),
            ])
            p.contentView = bg
            panel = p
        }
        label.stringValue = text
        // Fit the panel to the text, then centre it on screen.
        let width = min(max(label.intrinsicContentSize.width + 16 + 10 + 56, 220), 520)
        panel?.setContentSize(NSSize(width: width, height: 76))
        position()
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// Centre on the built-in screen when there is one: it never moves during a switch.
    private func position() {
        guard let p = panel else { return }
        let builtin = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false }
        guard let f = (builtin ?? NSScreen.main)?.frame else { return }
        p.setFrameOrigin(NSPoint(x: (f.midX - p.frame.width / 2).rounded(), y: (f.midY - p.frame.height / 2).rounded()))
    }
}
