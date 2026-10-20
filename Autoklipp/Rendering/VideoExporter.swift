import AVFoundation
import Foundation

/// Writes a built composition to a movie file.
enum VideoExporter {
    enum ExportError: Error {
        case sessionUnavailable
    }

    static func preset(for resolution: Resolution) -> String {
        switch resolution {
        case .hd1080: AVAssetExportPresetHighestQuality
        case .uhd4k: AVAssetExportPresetHEVCHighestQuality
        }
    }

    /// Exports to `url` (replacing any file there), reporting progress 0...1.
    static func export(
        _ built: BuiltComposition,
        resolution: Resolution,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset(for: resolution)) else {
            throw ExportError.sessionUnavailable
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)

        let monitor = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case let .exporting(exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
    }
}
