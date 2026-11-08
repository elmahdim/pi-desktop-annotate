import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

struct EvidenceFrame {
    let id: Int
    let image: CGImage
    let capturedAt: Date
}

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "pi.annotate.capture", qos: .utility)
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var latest: EvidenceFrame?
    private var sequence = 0
    var onError: (@MainActor (String) -> Void)?

    func start(displayID: CGDirectDisplayID, window: SCWindow? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "The primary display is unavailable."])
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else {
            throw NSError(domain: "Capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot exclude the annotation app from capture. Restart the companion."])
        }
        let filter = window.map { SCContentFilter(desktopIndependentWindow: $0) }
            ?? SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let width = window.map { Double($0.frame.width) * 2 } ?? Double(CGDisplayPixelsWide(displayID))
        let height = window.map { Double($0.frame.height) * 2 } ?? Double(CGDisplayPixelsHigh(displayID))
        let scale = min(1, 1920 / width, 1080 / height)
        config.width = max(2, Int(width * scale) / 2 * 2)
        config.height = max(2, Int(height * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        let next = SCStream(filter: filter, configuration: config, delegate: self)
        try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = next
        try await next.startCapture()
    }

    func snapshot() -> EvidenceFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let latest, Date().timeIntervalSince(latest.capturedAt) < 3 else { return nil }
        return latest
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        lock.withLock { latest = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let metadata = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = metadata.first?[.status] as? Int else { return }
        if status == SCFrameStatus.idle.rawValue {
            // A static desktop is still valid evidence; no new pixel copy needed.
            lock.withLock {
                if let frame = latest { latest = EvidenceFrame(id: frame.id, image: frame.image, capturedAt: Date()) }
            }
            return
        }
        guard status == SCFrameStatus.complete.rawValue else {
            lock.withLock { latest = nil }
            return
        }
        guard let buffer = sampleBuffer.imageBuffer else { return }
        let input = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(input, from: input.extent) else { return }
        lock.lock()
        sequence += 1
        latest = EvidenceFrame(id: sequence, image: image, capturedAt: Date())
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); latest = nil; lock.unlock()
        DispatchQueue.main.async { self.onError?(error.localizedDescription) }
    }
}
