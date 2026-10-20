import Foundation
import Photos

/// Saves finished films to Photos. Needs add-only access, never read access.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            String(localized: "Autoklipp is not allowed to add to Photos. You can change this in Settings.")
        }
    }

    static func save(videoAt url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .video, fileURL: url, options: nil)
        }
    }
}
