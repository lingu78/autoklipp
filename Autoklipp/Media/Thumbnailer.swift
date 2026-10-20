import AVFoundation
import SwiftUI
import UIKit

/// Small preview images for picked media.
enum Thumbnailer {
    static func image(for media: ImportedMedia, maxPixelSize: Int = 240) async -> UIImage? {
        if media.item.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            let time = CMTime(seconds: min(1, media.item.duration / 2), preferredTimescale: 600)
            guard let result = try? await generator.image(at: time) else { return nil }
            return UIImage(cgImage: result.image)
        }
        let url = media.url
        return await Task.detached(priority: .utility) {
            StillImageCache.decode(url: url, maxPixelSize: maxPixelSize).map { UIImage(cgImage: $0) }
        }.value
    }
}

struct MediaThumbnail: View {
    let media: ImportedMedia
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if media.item.kind == .video {
                    Text(Formatting.clock(media.item.duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: .rect(cornerRadius: 4))
                        .padding(4)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .task(id: media.id) {
                image = await Thumbnailer.image(for: media)
            }
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: Text {
        switch media.item.kind {
        case .video: Text("Video, \(Formatting.duration(media.item.duration))")
        case .livePhoto: Text("Live Photo")
        case .photo: Text("Photo")
        }
    }
}
