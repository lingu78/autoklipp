import Foundation

/// The kind of a picked library item.
public enum MediaKind: String, Codable, Sendable, Hashable {
    case photo
    case video
    /// A Live Photo, used as a still in the edit.
    case livePhoto

    /// Stills are shown for a chosen duration (with Ken Burns); videos play their own frames.
    public var isStill: Bool { self != .video }
}

/// A geographic coordinate (WGS84).
public struct GeoPoint: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One picked photo or video, described by its metadata only.
public struct MediaItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: MediaKind
    /// Capture date from the file's metadata, if known.
    public var creationDate: Date?
    /// Duration in seconds; 0 for stills.
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasAudio: Bool
    public var location: GeoPoint?

    public init(
        id: String,
        kind: MediaKind,
        creationDate: Date? = nil,
        duration: Double = 0,
        pixelWidth: Int = 1920,
        pixelHeight: Int = 1080,
        hasAudio: Bool = false,
        location: GeoPoint? = nil
    ) {
        self.id = id
        self.kind = kind
        self.creationDate = creationDate
        self.duration = kind.isStill ? 0 : max(0, duration)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasAudio = hasAudio
        self.location = location
    }
}

extension Array where Element == MediaItem {
    /// Stable chronological order. Items without a capture date keep their picked order and go last.
    public func chronological() -> [MediaItem] {
        enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.creationDate, rhs.element.creationDate) {
                case let (l?, r?) where l != r: return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// Total length of the raw material: video durations plus nothing for stills.
    public var totalVideoDuration: Double {
        reduce(0) { $0 + ($1.kind == .video ? $1.duration : 0) }
    }
}
