import AVFoundation
import CoreGraphics
import Foundation
import VideoToolbox

/// The film's frames read through its compositor with an asset reader, the way the export reads
/// them, for a preview whose player cannot show them (see PreviewSession.frames).
///
/// Frames are read a little ahead of the time asked for, on a queue of their own. A time behind
/// the last frame shown, or well ahead of what has been read, starts reading again from there:
/// that is how seeking and edits reach the picture.
final class ComposedFrames: @unchecked Sendable {
    private let built: BuiltComposition
    private let frameDuration: Double
    private let queue = DispatchQueue(label: "se.autoklipp.preview-frames", qos: .userInitiated)
    private let capacity = 6

    private let lock = NSLock()
    // Guarded by the lock.
    private var buffered: [(time: Double, image: CGImage)] = []
    private var generation = 0
    private var readFrom = 0.0
    private var lastRead: Double?
    private var finished = false
    private var reading = false
    private var shownTime: Double?
    private var started = false
    private var storedImage: CGImage?

    /// The frame shown last, for a view made for the other layout to show at once.
    var lastImage: CGImage? { lock.withLock { storedImage } }

    // Used only on the queue.
    private var reader: AVAssetReader?
    private var output: AVAssetReaderVideoCompositionOutput?

    init(built: BuiltComposition, keeping image: CGImage? = nil) {
        self.built = built
        let seconds = built.videoComposition.frameDuration.seconds
        frameDuration = seconds.isFinite && seconds > 0 ? seconds : 1.0 / 30
        storedImage = image
    }

    deinit {
        reader?.cancelReading()
    }

    /// The frame to show at `time` when it differs from the one shown last, or nil.
    func newImage(at time: Double) -> CGImage? {
        let restartAt: Double?
        var image: CGImage?
        var readMore = false
        lock.lock()
        if !started {
            restartAt = time
        } else if time < (shownTime ?? readFrom) - 0.1 {
            // Back in the film.
            restartAt = time
        } else if !finished, time > (lastRead ?? readFrom) + 1.0 {
            // Ahead of what is being read: a jump, or reading fell behind.
            restartAt = time
        } else {
            restartAt = nil
            if let index = buffered.lastIndex(where: { $0.time <= time + frameDuration }) {
                let frame = buffered[index]
                buffered.removeFirst(index + 1)
                shownTime = frame.time
                storedImage = frame.image
                image = frame.image
            }
            readMore = !reading && !finished && buffered.count < capacity
            if readMore { reading = true }
        }
        if let restartAt {
            started = true
            generation += 1
            buffered = []
            readFrom = max(0, restartAt)
            lastRead = nil
            finished = false
            shownTime = nil
            reading = true
            readMore = true
        }
        let current = generation
        let start = restartAt == nil ? nil : readFrom
        lock.unlock()

        if readMore {
            queue.async { [self] in fill(generation: current, restartingAt: start) }
        }
        return image
    }

    private func fill(generation current: Int, restartingAt start: Double?) {
        if let start {
            reader?.cancelReading()
            reader = nil
            output = nil
            do {
                try startReading(at: start)
            } catch {
                ClipCompositor.trace?("reading the preview's frames failed: \(error)")
                finish(generation: current)
                return
            }
        }
        while true {
            let wanted: Bool = lock.withLock { generation == current && buffered.count < capacity }
            guard wanted, let output, reader?.status == .reading else { break }
            guard let sample = output.copyNextSampleBuffer() else {
                finish(generation: current)
                return
            }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            guard let image else { continue }
            lock.withLock {
                guard generation == current else { return }
                buffered.append((time, image))
                lastRead = time
            }
        }
        lock.withLock { if generation == current { reading = false } }
    }

    private func finish(generation current: Int) {
        lock.withLock {
            guard generation == current else { return }
            finished = true
            reading = false
        }
    }

    private func startReading(at start: Double) throws {
        let composition = built.composition
        let reader = try AVAssetReader(asset: composition)
        let end = composition.duration
        let from = CMTime(seconds: start, preferredTimescale: 600)
        if from < end {
            reader.timeRange = CMTimeRange(start: from, end: end)
        }
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks.filter { $0.mediaType == .video },
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
            ]
        )
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
        self.reader = reader
        self.output = output
    }
}
