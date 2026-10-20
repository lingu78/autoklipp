import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// The single instruction covering the whole film; it carries the renderer for the timeline.
final class ClipInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let renderer: FrameRenderer

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], renderer: FrameRenderer) {
        self.timeRange = timeRange
        requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        self.renderer = renderer
    }
}

/// Custom compositor: every output frame is drawn by `FrameRenderer` with Core Image.
final class ClipCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    enum CompositorError: Error {
        case missingInstruction
        case noOutputBuffer
    }

    private let queue = DispatchQueue(label: "se.autoklipp.compositor", qos: .userInitiated)
    private let gpuContext = CIContext(options: [.cacheIntermediates: false])
    private let cpuContext = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private let cancelLock = NSLock()
    private var cancelling = false

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelLock.withLock({ cancelling }) {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool { render(request) }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelLock.withLock { cancelling = true }
        queue.async { [self] in
            cancelLock.withLock { cancelling = false }
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ClipInstruction else {
            request.finish(with: CompositorError.missingInstruction)
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.noOutputBuffer)
            return
        }
        let time = request.compositionTime.seconds
        let image = instruction.renderer.image(at: time) { trackID in
            request.sourceFrame(byTrackID: trackID)
        }
        let context = RenderEnvironment.isInBackground ? cpuContext : gpuContext
        let size = request.renderContext.size
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}
