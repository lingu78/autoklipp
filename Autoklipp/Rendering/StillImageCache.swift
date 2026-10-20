import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Decodes stills at the size the film needs and keeps the last few in memory.
///
/// Full-resolution decoding of every photo would not fit in memory, so each still is decoded
/// once as an upright, downsampled bitmap just large enough for the frame plus Ken Burns zoom.
final class StillImageCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: String, image: CIImage)] = []
    private let capacity: Int

    init(capacity: Int = 4) {
        self.capacity = capacity
    }

    func image(url: URL, maxPixelSize: Int) -> CIImage? {
        let key = "\(url.path)#\(maxPixelSize)"
        if let hit = lock.withLock({ entries.first { $0.key == key }?.image }) { return hit }
        guard let decoded = Self.decode(url: url, maxPixelSize: maxPixelSize) else { return nil }
        let image = CIImage(cgImage: decoded)
        lock.withLock {
            entries.removeAll { $0.key == key }
            entries.append((key, image))
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
        return image
    }

    static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixelSize),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
