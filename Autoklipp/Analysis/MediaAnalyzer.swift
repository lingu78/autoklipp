import AVFoundation
import ClipCore
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Scores photos and 0.5 s video segments with Vision and Accelerate: sharpness, faces, motion,
/// camera shake, exposure and loudness (spec F3), plus classification labels for the director.
///
/// Works on small proxy frames only (long side 512 px); whole videos are never decoded into memory.
enum MediaAnalyzer {
    /// Video frames are fetched at this size; sharpness is measured on it.
    static let proxySide = 512
    /// Photos are measured larger, since they are shown longer and closer (Ken Burns).
    static let stillSide = 1024
    /// Motion is compared on smaller copies.
    static let motionSide = 256
    /// Labels below this confidence are dropped.
    static let labelConfidence: Float = 0.3
    /// Video frames requested from the generator at a time (8 s of video); bounds the frames
    /// held in memory while they wait to be measured.
    static let framesPerRequest = 16

    static func analyse(_ media: ImportedMedia) async throws -> MediaAnalysis {
        if media.item.kind == .video {
            return try await analyseVideo(media)
        }
        return try await analyseStill(media)
    }

    // MARK: Stills

    static func analyseStill(_ media: ImportedMedia) async throws -> MediaAnalysis {
        guard let image = StillImageCache.decode(url: media.url, maxPixelSize: stillSide) else {
            throw MediaMetadataReader.ReadError.unreadableImage
        }
        var metrics = FrameMetrics()
        if let gray = GrayImage(image, longSide: stillSide) {
            metrics.sharpness = ImageMetrics.sharpness(gray)
            metrics.exposure = ImageMetrics.exposure(gray)
        }
        metrics.motion = 0
        metrics.shake = 0
        let faces = await detectFaces(in: image)
        metrics.faceCount = faces.count
        metrics.faceQuality = faces.map(\.quality).max() ?? 0
        if let aesthetics = try? await CalculateImageAestheticsScoresRequest().perform(on: image, orientation: nil) {
            metrics.aesthetics = aesthetics.isUtility ? 0.1 : Double((aesthetics.overallScore + 1) / 2)
        }
        return MediaAnalysis(
            mediaID: media.id,
            still: metrics,
            stillSignature: ImageMetrics.colorSignature(image),
            faceRegions: faces.map(\.rect),
            labels: await labels(for: [image])
        )
    }

    // MARK: Videos

    static func analyseVideo(_ media: ImportedMedia) async throws -> MediaAnalysis {
        let asset = AVURLAsset(url: media.url)
        let duration = try await asset.load(.duration).seconds
        let count = max(1, Int((duration / Timing.segmentLength - 1e-9).rounded(.up)))
        let times = (0..<count).map { index in
            CMTime(seconds: min(duration - 0.05, (Double(index) + 0.5) * Timing.segmentLength), preferredTimescale: 600)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: proxySide, height: proxySide)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        // Segments are measured in time order as their frames arrive, a few frames per request, so
        // memory stays the same however long the video is. Only the previous segment's grey copy
        // and the three frames sampled for labels are kept.
        let registration = TrackTranslationalImageRegistrationRequest()
        // Camera displacement since the previous sample, as fractions of the frame width; nil
        // where it could not be measured.
        var displacements = [CGVector?](repeating: nil, count: count)
        var segments: [SegmentAnalysis] = []
        segments.reserveCapacity(count)
        var previousArrived = false
        var previousGray: GrayImage?
        var lastFaces: [DetectedFace] = []
        let labelPositions = Set([0, count / 2, count - 1])
        var labelFrames: [Int: CGImage] = [:]

        for chunkStart in stride(from: 0, to: count, by: framesPerRequest) {
            let chunk = Array(times[chunkStart..<min(count, chunkStart + framesPerRequest)])
            var frames: [Int: CGImage] = [:]
            for await result in generator.images(for: chunk) {
                try Task.checkCancellation()
                if case let .success(requested, image, _) = result, let offset = chunk.firstIndex(of: requested) {
                    frames[chunkStart + offset] = image
                }
            }

            for position in chunkStart..<(chunkStart + chunk.count) {
                try Task.checkCancellation()
                let frame = frames.removeValue(forKey: position)
                var metrics = FrameMetrics()
                var signature: [Float]?
                var gray: GrayImage?
                if let frame {
                    // The request is stateful: every frame goes through it, in time order.
                    let alignment = try? await registration.perform(on: frame, orientation: nil)
                    if previousArrived, let transform = alignment?.alignmentTransform {
                        displacements[position] = CGVector(
                            dx: transform.tx / CGFloat(frame.width), dy: transform.ty / CGFloat(frame.width)
                        )
                    }
                    gray = GrayImage(frame, longSide: motionSide)
                }
                if let frame, let gray {
                    if let detail = GrayImage(frame, longSide: proxySide) {
                        metrics.sharpness = ImageMetrics.sharpness(detail)
                        metrics.exposure = ImageMetrics.exposure(detail)
                    }
                    if let previousGray {
                        // Compensate the camera move; the sign convention is not relied upon, the
                        // best-aligned of the candidates is taken.
                        let displacement = displacements[position] ?? .zero
                        let dx = Int((displacement.dx * CGFloat(gray.width)).rounded())
                        let dy = Int((displacement.dy * CGFloat(gray.width)).rounded())
                        let candidates = [(dx, dy), (-dx, dy), (dx, -dy), (-dx, -dy)]
                        metrics.motion = candidates.map { ImageMetrics.motion(previousGray, gray, dx: $0.0, dy: $0.1) }.min() ?? 0
                    } else {
                        metrics.motion = 0.3
                    }
                    // Faces once per second; the in-between segment reuses the last result.
                    if position % 2 == 0 { lastFaces = await detectFaces(in: frame) }
                    signature = ImageMetrics.colorSignature(frame)
                } else {
                    metrics.sharpness = 0
                }
                metrics.faceCount = lastFaces.count
                metrics.faceQuality = lastFaces.map(\.quality).max() ?? 0
                segments.append(
                    SegmentAnalysis(
                        start: Double(position) * Timing.segmentLength,
                        duration: min(Timing.segmentLength, duration - Double(position) * Timing.segmentLength),
                        metrics: metrics,
                        signature: signature
                    )
                )
                if let frame, labelPositions.contains(position) { labelFrames[position] = frame }
                previousArrived = frame != nil
                previousGray = gray
            }
        }

        // Shake needs the displacements on both sides of a segment, loudness reads the sound.
        let shakes = ImageMetrics.shake(displacements: displacements)
        let loudness = (try? await audioLevels(asset: asset, segments: count)) ?? []
        for position in segments.indices {
            segments[position].metrics.shake = shakes.indices.contains(position) ? shakes[position] : 0
            segments[position].metrics.audioLevel = loudness.indices.contains(position) ? loudness[position] : nil
        }

        let sampled = [0, count / 2, count - 1].compactMap { labelFrames[$0] }
        return MediaAnalysis(mediaID: media.id, segments: segments, labels: await labels(for: sampled))
    }

    // MARK: Vision helpers

    struct DetectedFace: Sendable {
        /// Normalised, origin top left.
        var rect: ClipCore.NormalizedRect
        var quality: Double
    }

    static func detectFaces(in image: CGImage) async -> [DetectedFace] {
        guard let faces = try? await DetectFaceCaptureQualityRequest().perform(on: image, orientation: nil) else { return [] }
        return faces.map { face in
            let box = face.boundingBox.cgRect
            // Vision's origin is bottom left.
            let rect = ClipCore.NormalizedRect(
                x: Double(box.origin.x), y: Double(1 - box.origin.y - box.height),
                width: Double(box.width), height: Double(box.height)
            )
            return DetectedFace(rect: rect, quality: Double(face.captureQuality?.score ?? 0.5))
        }
    }

    static func labels(for images: [CGImage]) async -> [String] {
        var confidence: [String: Float] = [:]
        for image in images {
            guard let observations = try? await ClassifyImageRequest().perform(on: image, orientation: nil) else { continue }
            for observation in observations where observation.confidence >= labelConfidence {
                confidence[observation.identifier] = max(confidence[observation.identifier] ?? 0, observation.confidence)
            }
        }
        return confidence.sorted { $0.value > $1.value }.prefix(10).map(\.key)
    }

    // MARK: Audio

    /// Loudness 0...1 per segment from the RMS level (-50 dBFS → 0, -10 dBFS → 1).
    static func audioLevels(asset: AVURLAsset, segments: Int) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let sampleRate = 16_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ]
        )
        reader.add(output)
        guard reader.startReading() else { return [] }
        let perSegment = Int(sampleRate * Timing.segmentLength)
        var sums = [Double](repeating: 0, count: segments)
        var counts = [Int](repeating: 0, count: segments)
        var sampleIndex = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = floats.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == noErr else { continue }
            for (offset, sample) in floats.enumerated() {
                let segment = (sampleIndex + offset) / perSegment
                guard segment < segments else { break }
                sums[segment] += Double(sample) * Double(sample)
                counts[segment] += 1
            }
            sampleIndex += floats.count
        }
        return zip(sums, counts).map { sum, count in
            guard count > 0 else { return 0 }
            let rms = (sum / Double(count)).squareRoot()
            let decibels = 20 * log10(max(rms, 1e-6))
            return min(1, max(0, (decibels + 50) / 40))
        }
    }
}
