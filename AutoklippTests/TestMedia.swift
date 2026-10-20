import AVFoundation
import ClipCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import Autoklipp

/// Synthetic photos and videos written to disk for tests.
enum TestMedia {
    static let baseDate = ISO8601DateFormatter().date(from: "2026-06-21T10:00:00Z")!

    static func makeFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "AutoklippTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    struct RGB: Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        static let palette: [RGB] = [
            RGB(red: 0.9, green: 0.3, blue: 0.2), RGB(red: 0.2, green: 0.6, blue: 0.9), RGB(red: 0.3, green: 0.8, blue: 0.4),
            RGB(red: 0.95, green: 0.8, blue: 0.2), RGB(red: 0.6, green: 0.3, blue: 0.8), RGB(red: 0.2, green: 0.8, blue: 0.8),
        ]
    }

    /// A JPEG with a coloured background, a few shapes and an EXIF capture date.
    static func writeImage(to url: URL, width: Int, height: Int, color: RGB, date: Date?) throws {
        let context = try bitmapContext(width: width, height: height)
        draw(in: context, width: width, height: height, color: color, phase: 0.3)
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw TestError.couldNotWrite }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date),
                kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestError.couldNotWrite }
    }

    /// An H.264 movie with a moving square on a coloured background and a creation date;
    /// with `toneLevel`, also a 440 Hz AAC sound track at that amplitude (0...1).
    static func writeVideo(
        to url: URL, duration: Double, width: Int, height: Int, color: RGB, date: Date?, toneLevel: Float? = nil
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        var soundInput: AVAssetWriterInput?
        if toneLevel != nil {
            let sound = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64_000,
                ]
            )
            sound.expectsMediaDataInRealTime = false
            writer.add(sound)
            soundInput = sound
        }
        if let date {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = ISO8601DateFormatter().string(from: date) as NSString
            writer.metadata = [item]
        }
        guard writer.startWriting() else { throw writer.error ?? TestError.couldNotWrite }
        writer.startSession(atSourceTime: .zero)
        let tone = try soundInput.map { try ToneWriter(input: $0, level: toneLevel ?? 0.5) }
        let frames = Int(duration * 30)
        for frame in 0..<frames {
            // Keep the sound a little ahead of the pictures so the writer can interleave.
            try await tone?.append(until: min(duration, Double(frame) / 30 + 0.5))
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw TestError.couldNotWrite }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw TestError.couldNotWrite }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                draw(in: context, width: width, height: height, color: color, phase: Double(frame) / Double(max(1, frames)))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        try await tone?.append(until: duration)
        soundInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestError.couldNotWrite }
    }

    /// `count` items alternating photo/video, a minute apart, in shuffled pick order.
    static func mixedSet(count: Int, in folder: URL) async throws -> [ImportedMedia] {
        var result: [ImportedMedia] = []
        for index in 0..<count {
            let date = baseDate.addingTimeInterval(Double(index) * 60)
            let color = RGB.palette[index % RGB.palette.count]
            let id = "item-\(index)"
            if index % 2 == 0 {
                let portrait = index % 4 == 0
                let (width, height) = portrait ? (1200, 1600) : (1600, 1200)
                let url = folder.appending(path: "\(id).jpg")
                try writeImage(to: url, width: width, height: height, color: color, date: date)
                let info = try MediaMetadataReader.readImage(at: url)
                let item = MediaItem(id: id, kind: .photo, creationDate: info.date, pixelWidth: info.width, pixelHeight: info.height)
                result.append(ImportedMedia(item: item, url: url))
            } else {
                let duration = Double(2 + (index * 3) % 7)
                let portrait = index % 3 == 0
                let (width, height) = portrait ? (360, 640) : (640, 360)
                let url = folder.appending(path: "\(id).mov")
                try await writeVideo(to: url, duration: duration, width: width, height: height, color: color, date: date)
                let info = try await MediaMetadataReader.readVideo(at: url)
                let item = MediaItem(
                    id: id, kind: .video, creationDate: info.date, duration: info.duration,
                    pixelWidth: info.width, pixelHeight: info.height, hasAudio: info.hasAudio
                )
                result.append(ImportedMedia(item: item, url: url))
            }
        }
        var generator = SeededGenerator(seed: 3)
        return result.shuffled(using: &generator)
    }

    static func solidImage(to url: URL, color: RGB, width: Int = 400, height: Int = 300) throws {
        let context = try bitmapContext(width: width, height: height)
        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw TestError.couldNotWrite }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TestError.couldNotWrite }
    }

    private static func bitmapContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestError.couldNotWrite }
        return context
    }

    private static func draw(in context: CGContext, width: Int, height: Int, color: RGB, phase: Double) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.9)
        let side = min(w, h) * 0.25
        context.fill(CGRect(x: (w - side) * phase, y: (h - side) / 2, width: side, height: side))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.5)
        context.fillEllipse(in: CGRect(x: w * 0.6, y: h * 0.6, width: side * 0.8, height: side * 0.8))
    }

    enum TestError: Error {
        case couldNotWrite
    }
}

/// Writes a sine tone as 1024-sample PCM buffers; the writer encodes them to AAC.
final class ToneWriter {
    let input: AVAssetWriterInput
    let level: Float
    let format: CMAudioFormatDescription
    let rate = 44_100
    var position = 0

    init(input: AVAssetWriterInput, level: Float) throws {
        self.input = input
        self.level = level
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        guard let format else { throw TestMedia.TestError.couldNotWrite }
        self.format = format
    }

    func append(until seconds: Double) async throws {
        let total = Int(seconds * Double(rate))
        while position < total {
            let count = min(1024, total - position)
            var samples = (0..<count).map { level * sin(2 * Float.pi * 440 * Float(position + $0) / Float(rate)) }
            let bytes = count * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
            )
            guard let block else { throw TestMedia.TestError.couldNotWrite }
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(position), timescale: CMTimeScale(rate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            guard let sample else { throw TestMedia.TestError.couldNotWrite }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            input.append(sample)
            position += count
        }
    }
}
