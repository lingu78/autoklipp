import AVFoundation
import ClipCore
import Foundation
import Observation

/// Steps of the main flow after the media are picked.
enum Route: Hashable {
    case length
    case style
    case generate
    case preview
}

/// Root state: the project being made and where in the flow the user is.
@MainActor
@Observable
final class AppModel {
    var path: [Route] = []
    private(set) var draft: ProjectDraft
    /// The film currently shown in the preview.
    var preview: PreviewSession?

    init() {
        draft = ProjectDraft()
    }

    /// Throws away the current project, including its copied media.
    func startOver() {
        let storage = draft.storage
        preview?.player.pause()
        preview = nil
        draft = ProjectDraft()
        path = []
        Task.detached { storage.removeAll() }
    }
}

/// How the user chose the film length.
enum LengthChoice: Hashable {
    case auto
    case preset(Double)
    case custom(Double)
}

/// Everything about the film being made. Phase 4 persists this with SwiftData.
@MainActor
@Observable
final class ProjectDraft {
    static let presetLengths: [Double] = [15, 30, 60, 180, 300, 600]

    let id = UUID()
    let storage: ProjectStorage
    var media: [ImportedMedia] = []
    /// Items that could not be read and were skipped.
    var skippedCount = 0
    var lengthChoice: LengthChoice = .preset(60)
    var style: StyleID = .travel
    var musicTrackID: String = MusicCatalog.defaultTrack?.id ?? ""
    var format: AspectFormat = .portrait
    var seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    var edl: EditDecisionList?

    init() {
        storage = ProjectStorage(projectID: id)
    }

    var mediaItems: [MediaItem] { media.map(\.item) }

    var totalVideoDuration: Double { mediaItems.totalVideoDuration }
    var photoCount: Int { media.filter { $0.item.kind.isStill }.count }
    var videoCount: Int { media.filter { $0.item.kind == .video }.count }

    /// The length the planner aims for.
    var targetDuration: Double {
        switch lengthChoice {
        case .auto: AutoLength.suggest(for: mediaItems)
        case let .preset(seconds), let .custom(seconds): seconds
        }
    }

    var musicTrack: MusicTrack? { MusicCatalog.track(id: musicTrackID) ?? MusicCatalog.defaultTrack }

    var mediaURLs: [String: URL] {
        Dictionary(uniqueKeysWithValues: media.map { ($0.item.id, $0.url) })
    }
}

/// A generated film ready to watch.
@MainActor
@Observable
final class PreviewSession {
    let edl: EditDecisionList
    let built: BuiltComposition
    let player: AVPlayer

    init(edl: EditDecisionList, built: BuiltComposition) {
        self.edl = edl
        self.built = built
        player = AVPlayer(playerItem: built.makePlayerItem())
    }
}
