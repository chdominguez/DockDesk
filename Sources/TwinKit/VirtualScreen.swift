import CVirtualDisplay
import CoreGraphics
import DockKit
import Foundation

/// One virtual monitor, backed by CoreGraphics' private CGVirtualDisplay.
/// It exists for as long as this object is alive.
public final class VirtualScreen {
    private let display: CGVirtualDisplay
    public let width: Int
    public let height: Int
    public var id: CGDirectDisplayID { display.displayID }

    public init?(name: String, serial: UInt32, width: Int, height: Int, hz: Double) {
        let desc = CGVirtualDisplayDescriptor()
        desc.queue = DispatchQueue.main
        desc.name = name
        desc.maxPixelsWide = UInt32(width)
        desc.maxPixelsHigh = UInt32(height)
        desc.sizeInMillimeters = CGSize(width: 527, height: 296) // 23.8" 16:9
        desc.vendorID = VirtualVendor.id
        desc.productID = 0x5444
        desc.serialNum = serial
        guard let d = CGVirtualDisplay(descriptor: desc) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: hz)]
        guard d.apply(settings), d.displayID != 0 else { return nil }
        display = d
        self.width = width
        self.height = height
    }
}
