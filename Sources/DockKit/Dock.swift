import CDock
import CoreGraphics
import Foundation

/// What the attached hub can do, derived from a `td_info` snapshot.
public enum DockState: Equatable {
    case noDock                 // no external DisplayPort branch device
    case unsupported(String)    // not a Synaptics hub we know
    case firmwareTooNew(String) // known hub, but the split feature was removed
    case ready(String)          // split feature available
}

public struct DockInfo {
    public let raw: td_info
    public var firmware: String { String(format: "%02d.%02d.%02d", raw.fw.0, raw.fw.1, raw.fw.2) }
    public var chip: String { String(format: "VMM%04X", raw.chip_id) }
    public var isSplitMode: Bool { raw.mode_byte & 0x0f == 2 }
    /// The hub's firmware starts in split mode (DockDesk's modified 05.07.04), so no re-detect is needed after a reconnect.
    public var bootsInSplitMode: Bool { raw.boot_mode_byte & 0x0f == 2 }
    public var offersWideTiming: Bool { raw.wide_timing }
    public var isSplitting: Bool { raw.splitting }
    public var monitors: Int { Int(raw.monitors) }

    /// ViewXpand exists in 05.07.04 and older; Dell removed it by 05.07.07.
    public var hasSplitFeature: Bool {
        let v = (Int(raw.fw.0), Int(raw.fw.1), Int(raw.fw.2))
        return v.0 < 5 || (v.0 == 5 && (v.1 < 7 || (v.1 == 7 && v.2 <= 4)))
    }

    public var state: DockState {
        guard raw.rc_supported, raw.oui.0 == 0x90, raw.oui.1 == 0xcc, raw.oui.2 == 0x24 else { return .unsupported("not a Synaptics MST hub") }
        guard raw.chip_id == 0x5331, raw.layout_known else { return .unsupported("\(chip) with unknown layout") }
        return hasSplitFeature ? .ready(firmware) : .firmwareTooNew(firmware)
    }
}

public enum DockError: Error, CustomStringConvertible {
    case noDock, query(Int32), setMode(Int32), softUnplug(Int32), noWideMode, noExternalDisplay
    public var description: String {
        switch self {
        case .noDock: return "no dock found on a DisplayPort output"
        case .query(let c): return "could not query the hub (\(c))"
        case .setMode(let c): return "could not set the hub mode (\(c))"
        case .softUnplug(let c): return "could not switch a monitor off over DDC (\(c))"
        case .noWideMode: return "macOS does not offer the requested display mode"
        case .noExternalDisplay: return "no external display"
        }
    }
}

public enum Dock {
    public static func info() throws -> DockInfo {
        guard let d = td_open() else { throw DockError.noDock }
        defer { td_close(d) }
        var i = td_info()
        let r = td_get_info(d, &i)
        if r != 0 { throw DockError.query(r) }
        return DockInfo(raw: i)
    }

    public static func state() -> DockState { (try? info().state) ?? .noDock }

    public static func setSplit(_ on: Bool) throws {
        guard let d = td_open() else { throw DockError.noDock }
        defer { td_close(d) }
        let r = td_set_edid_mode(d, on ? TD_MODE_SPLIT : TD_MODE_MIRROR)
        if r != 0 { throw DockError.setMode(r) }
    }

    /// Turn one monitor off over DDC/CI so the hub re-detects it when its power button is pressed.
    /// Replaces unplugging a monitor cable; see `td_soft_unplug`.
    public static func softUnplug() throws {
        guard let d = td_open() else { throw DockError.noDock }
        defer { td_close(d) }
        let r = td_soft_unplug(d)
        if r != 0 { throw DockError.softUnplug(r) }
    }

    /// The physical external display (ignores virtual displays, which report vendor 0x7477).
    public static func externalDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) != VirtualVendor.id }
    }

    public static func setNativeMode(width: Int, height: Int, maxHz: Int = 240) throws {
        guard let disp = externalDisplay() else { throw DockError.noExternalDisplay }
        if td_set_native_mode(disp, UInt32(width), UInt32(height), UInt32(maxHz)) != 0 { throw DockError.noWideMode }
    }
}

public enum VirtualVendor { public static let id: UInt32 = 0x7477 }

/// One serial queue for everything that talks to the dock, so polling can never interleave with a firmware job.
public enum DockQueue { public static let shared = DispatchQueue(label: "dockdesk.dock") }
