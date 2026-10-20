import ClipCore
import Foundation
import SwiftData

/// A film the user can open again (F15). The project itself is one JSON snapshot; media and
/// the user's own song live as files in the project's folder.
@Model
final class SavedProject {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var duration: Double
    var payload: Data
    @Attribute(.externalStorage) var thumbnail: Data?

    init(id: UUID, title: String, duration: Double, payload: Data) {
        self.id = id
        createdAt = .now
        updatedAt = .now
        self.title = title
        self.duration = duration
        self.payload = payload
    }

    var snapshot: ProjectSnapshot? {
        try? JSONDecoder().decode(ProjectSnapshot.self, from: payload)
    }
}

/// Everything needed to reopen a project, with file names relative to its folder (the app's
/// container path can change between launches).
struct ProjectSnapshot: Codable, Sendable {
    struct StoredMedia: Codable, Sendable {
        var item: MediaItem
        var fileName: String
    }

    struct StoredSong: Codable, Sendable {
        var id: String
        var title: String
        var fileName: String
        var info: TrackInfo
    }

    var version = 1
    var media: [StoredMedia]
    var analyses: [String: MediaAnalysis]
    var skippedCount: Int
    var lengthChoice: LengthChoice
    var style: StyleID
    var musicTrackID: String
    var musicChosenByUser: Bool
    var customSong: StoredSong?
    var originalAudio: Bool
    var format: AspectFormat
    var seed: UInt64
    var exclusions: [Exclusion]
    var title: String
    var endCredit: String
    var edl: EditDecisionList?
}
