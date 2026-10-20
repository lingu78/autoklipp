import AVFoundation
import ClipCore
import Foundation
import ImageIO

/// Reads capture date, size, duration and location from picked files.
///
/// The app works without photo library access, so metadata comes from the files themselves:
/// EXIF/TIFF for images and QuickTime metadata for videos.
enum MediaMetadataReader {
    enum ReadError: Error {
        case unreadableImage
        case noVideoTrack
        case notPlayable
    }

    struct ImageInfo: Sendable {
        var date: Date?
        var width: Int
        var height: Int
        var location: GeoPoint?
    }

    struct VideoInfo: Sendable {
        var date: Date?
        var duration: Double
        var width: Int
        var height: Int
        var hasAudio: Bool
        var location: GeoPoint?
    }

    static func readImage(at url: URL) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ReadError.unreadableImage }

        var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        guard width > 0, height > 0 else { throw ReadError.unreadableImage }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateText = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff?[kCGImagePropertyTIFFDateTime] as? String
        let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String
        let date = dateText.flatMap { exifDate($0, offset: offset) }

        var location: GeoPoint?
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
            let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        {
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W"
            location = GeoPoint(latitude: south ? -latitude : latitude, longitude: west ? -longitude : longitude)
        }
        return ImageInfo(date: date, width: width, height: height, location: location)
    }

    static func readVideo(at url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        guard playable else { throw ReadError.notPlayable }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReadError.noVideoTrack }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let displayed = naturalSize.applying(transform)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty

        var date: Date?
        if let item = try await asset.load(.creationDate) {
            date = try? await item.load(.dateValue)
            if date == nil, let text = try? await item.load(.stringValue) {
                date = ISO8601DateFormatter().date(from: text)
            }
        }

        var location: GeoPoint?
        let metadata = (try? await asset.load(.metadata)) ?? []
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataLocationISO6709).first,
            let text = try? await item.load(.stringValue)
        {
            location = iso6709(text)
        }

        return VideoInfo(
            date: date,
            duration: max(0, duration.seconds.isFinite ? duration.seconds : 0),
            width: Int(abs(displayed.width).rounded()),
            height: Int(abs(displayed.height).rounded()),
            hasAudio: hasAudio,
            location: location
        )
    }

    /// Parses "2026:07:14 18:03:27" with an optional "+02:00" offset; without one, local time.
    static func exifDate(_ text: String, offset: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func timeZone(fromOffset text: String) -> TimeZone? {
        let parts = text.dropFirst().split(separator: ":")
        guard let sign = text.first, sign == "+" || sign == "-", parts.count == 2,
            let hours = Int(parts[0]), let minutes = Int(parts[1])
        else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    /// Parses ISO 6709 strings such as "+59.3293+018.0686+012.345/".
    static func iso6709(_ text: String) -> GeoPoint? {
        var numbers: [Double] = []
        var current = ""
        for character in text {
            if character == "+" || character == "-" || character == "/" {
                if let value = Double(current) { numbers.append(value) }
                current = character == "/" ? "" : String(character)
            } else {
                current.append(character)
            }
        }
        if let value = Double(current) { numbers.append(value) }
        guard numbers.count >= 2, abs(numbers[0]) <= 90, abs(numbers[1]) <= 180 else { return nil }
        return GeoPoint(latitude: numbers[0], longitude: numbers[1])
    }
}
