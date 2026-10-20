import AVFoundation
import CoreVideo
import Foundation

/// A tiny black video stretched under the whole film.
///
/// The compositor draws every frame itself, including stills, but AVFoundation only asks for
/// frames where the composition has a video track. This carrier track guarantees that.
actor BlankVideo {
    static let shared = BlankVideo()

    enum BlankVideoError: Error {
        case writerFailed(String)
    }

    private var cached: URL?

    func url() async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        let url = URL.cachesDirectory.appending(path: "blank-v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await Self.write(to: url)
        }
        cached = url
        return url
    }

    private static func write(to url: URL) async throws {
        let temporary = url.deletingLastPathComponent().appending(path: "blank-\(UUID().uuidString).mov")
        let size = 128
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw BlankVideoError.writerFailed(writer.error?.localizedDescription ?? "start")
        }
        writer.startSession(atSourceTime: .zero)
        let frames = 60
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { throw BlankVideoError.writerFailed("pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw BlankVideoError.writerFailed("buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, 0, CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw BlankVideoError.writerFailed(writer.error?.localizedDescription ?? "finish")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
