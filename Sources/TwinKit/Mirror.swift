import AppKit
import CoreMedia
import ScreenCaptureKit

/// Captures one display and shows its frames in a CALayer.
final class Mirror: NSObject, SCStreamOutput, SCStreamDelegate {
    let layer = CALayer()
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "dockdesk.mirror", qos: .userInteractive)
    var onStop: ((Error) -> Void)?
    private(set) var frames = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "DockDesk", code: 1, userInfo: [NSLocalizedDescriptionKey: "display \(displayID) is not capturable"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = true
        cfg.queueDepth = 3
        cfg.scalesToFit = false
        let s = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb), let surface = CVPixelBufferGetIOSurface(px)?.takeUnretainedValue() else { return }
        frames += 1
        DispatchQueue.main.async { [layer] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
