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
    /// Set on the compositor's queue once the first frame is drawn.
    private var drewFirstFrame = false

    /// Receives a line for each new render context, the first frame and every failed request,
    /// and when the preview falls back to drawing the film itself; tests set it to find out why a
    /// player refuses a film. Nil, and silent, in the app.
    nonisolated(unsafe) static var trace: ((String) -> Void)?

    /// Buffers shared with the GPU (IOSurface, Metal), so Core Image reads and writes them in
    /// place instead of copying every frame through the CPU.
    static let sharedBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.sharedBufferAttributes }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.sharedBufferAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        Self.trace?(
            "render context \(newRenderContext.size), scale \(newRenderContext.renderScale), "
                + "high quality \(newRenderContext.highQualityRendering)"
        )
    }

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
            Self.trace?("request at \(request.compositionTime.seconds) s failed: no instruction")
            request.finish(with: CompositorError.missingInstruction)
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            Self.trace?("request at \(request.compositionTime.seconds) s failed: no output buffer")
            request.finish(with: CompositorError.noOutputBuffer)
            return
        }
        let time = request.compositionTime.seconds
        // Whether the frames handed over are shared with the GPU; nil while none was needed.
        var sourcesShared: Bool?
        let image = instruction.renderer.image(at: time) { trackID in
            let frame = request.sourceFrame(byTrackID: trackID)
            if let frame { sourcesShared = (sourcesShared ?? true) && CVPixelBufferGetIOSurface(frame) != nil }
            return frame
        }
        let context = RenderEnvironment.isInBackground ? cpuContext : gpuContext
        let size = request.renderContext.size
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        if !drewFirstFrame {
            drewFirstFrame = true
            let sources = sourcesShared.map { "\($0)" } ?? "none used"
            Self.trace?(
                "first frame at \(time) s, \(size), output shared with the GPU: \(CVPixelBufferGetIOSurface(output) != nil), "
                    + "sources shared with the GPU: \(sources), on the GPU: \(context === gpuContext)"
            )
        }
        request.finish(withComposedVideoFrame: output)
    }
}
