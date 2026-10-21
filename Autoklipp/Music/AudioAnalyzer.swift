import Accelerate
import AVFoundation
import ClipCore
import Foundation

/// Beat detection for the user's own songs: decodes the audio once at 22 kHz mono, computes a
/// spectral-flux onset envelope and loudness with Accelerate, and hands the envelope to
/// `BeatTracker` (ClipCore) for tempo and beats.
enum AudioAnalyzer {
    static let sampleRate = 22_050.0
    static let fftSize = 1024
    static let hop = 256
    /// Only the start of a longer file is decoded and used (a film is at most 10 minutes), so a
    /// long mix cannot fill the memory.
    static let maximumDuration = 15 * 60.0

    enum AnalysisError: Error {
        case noAudio
        case unreadable
        case noBeat
    }

    struct Envelope: Sendable {
        var onset: [Double]
        /// Onset frames per second.
        var frameRate: Double
        /// Time of onset frame 0's centre.
        var timeOffset: Double
        /// Loudness 0...1 per `loudnessRate`-th of a second.
        var loudness: [Double]
        var loudnessRate: Double
        var duration: Double
    }

    /// Timing facts for a song file, ready for `MusicLayout`.
    static func trackInfo(id: String, url: URL) async throws -> TrackInfo {
        let envelope = try await analyse(url: url)
        guard let result = BeatTracker.track(
            envelope: envelope.onset, frameRate: envelope.frameRate, timeOffset: envelope.timeOffset
        ) else { throw AnalysisError.noBeat }
        let sections = BeatTracker.sections(
            loudness: envelope.loudness, loudnessRate: envelope.loudnessRate, beats: result.beats
        )
        return TrackInfo(id: id, duration: envelope.duration, bpm: result.bpm, beats: result.beats, sections: sections)
    }

    static func analyse(url: URL) async throws -> Envelope {
        let samples = try await readMono(url: url)
        guard samples.count > fftSize * 4 else { throw AnalysisError.noAudio }
        return Envelope(
            onset: spectralFlux(samples),
            frameRate: sampleRate / Double(hop),
            timeOffset: Double(fftSize / 2) / sampleRate,
            loudness: loudness(samples, rate: 2),
            loudnessRate: 2,
            duration: Double(samples.count) / sampleRate
        )
    }

    /// Half-wave rectified change of the log-compressed magnitude spectrum, frame by frame.
    static func spectralFlux(_ samples: [Float]) -> [Double] {
        let bins = fftSize / 2
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        var windowed = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        var magnitude = [Float](repeating: 0, count: bins)
        var compressed = [Float](repeating: 0, count: bins)
        var previous = [Float](repeating: 0, count: bins)
        var difference = [Float](repeating: 0, count: bins)
        var count = Int32(bins)
        var flux: [Double] = []
        flux.reserveCapacity(samples.count / hop)

        var start = 0
        while start + fftSize <= samples.count {
            vDSP.multiply(samples[start..<(start + fftSize)], window, result: &windowed)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(bins))
                }
            }
            // Ignore DC and the packed Nyquist value in bin 0.
            magnitude[0] = 0
            vDSP.multiply(100, magnitude, result: &magnitude)
            vvlog1pf(&compressed, magnitude, &count)
            vDSP.subtract(compressed, previous, result: &difference)
            vDSP.clip(difference, to: 0...Float.greatestFiniteMagnitude, result: &difference)
            flux.append(Double(vDSP.sum(difference)))
            swap(&previous, &compressed)
            start += hop
        }
        if !flux.isEmpty { flux[0] = 0 }
        return flux
    }

    /// RMS loudness mapped to 0...1 (-50 dBFS → 0, -10 dBFS → 1), `rate` values per second.
    static func loudness(_ samples: [Float], rate: Double) -> [Double] {
        let window = max(1, Int(sampleRate / rate))
        var result: [Double] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            let rms = Double(vDSP.rootMeanSquare(samples[start..<end]))
            let decibels = 20 * log10(max(rms, 1e-6))
            result.append(min(1, max(0, (decibels + 50) / 40)))
            start = end
        }
        return result
    }

    /// The song as 22 kHz mono samples, at most its first `maximumDuration` seconds.
    static func readMono(url: URL, maximumDuration: Double = AudioAnalyzer.maximumDuration) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AnalysisError.noAudio }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
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
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AnalysisError.unreadable }
        let limit = Int(sampleRate * maximumDuration)
        var samples: [Float] = []
        // Room for the whole song (or the limit) plus a buffer, so the array never doubles.
        if duration.isFinite, duration > 0 {
            samples.reserveCapacity(Int(min(Double(limit), duration * sampleRate) + sampleRate))
        }
        while samples.count < limit, let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            let status = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length - length % MemoryLayout<Float>.size,
                    destination: bytes.baseAddress! + start * MemoryLayout<Float>.size
                )
            }
            if status != noErr { samples.removeLast(samples.count - start) }
        }
        if reader.status == .failed { throw reader.error ?? AnalysisError.unreadable }
        if samples.count >= limit {
            reader.cancelReading()
            samples.removeLast(samples.count - limit)
        }
        return samples
    }
}
