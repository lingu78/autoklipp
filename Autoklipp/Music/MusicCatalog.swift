import ClipCore
import Foundation

/// A song from the built-in library (Resources/Music/tracks.json).
struct MusicTrack: Identifiable, Hashable, Sendable, Decodable {
    struct Section: Hashable, Sendable, Decodable {
        let start: Double
        let end: Double
        let energy: Double
    }

    let id: String
    let title: String
    let file: String
    let bpm: Double
    let duration: Double
    let firstBeat: Double
    let beatCount: Int
    let loopStart: Double
    let loopEnd: Double
    let sections: [Section]
    let styles: [String]
    let license: String

    var url: URL? {
        let name = (file as NSString).deletingPathExtension
        let fileExtension = (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: fileExtension)
    }

    /// The generator writes every note, so beats follow exactly from tempo and first beat.
    var info: TrackInfo {
        let period = 60 / bpm
        return TrackInfo(
            id: id,
            duration: duration,
            bpm: bpm,
            beats: (0..<beatCount).map { firstBeat + Double($0) * period },
            loopStart: loopStart,
            loopEnd: loopEnd,
            sections: sections.map { MusicSection(start: $0.start, end: $0.end, energy: $0.energy) }
        )
    }

    func suits(_ style: StyleID) -> Bool { styles.contains(style.rawValue) }
}

enum MusicCatalog {
    private struct File: Decodable {
        let tracks: [MusicTrack]
    }

    static let tracks: [MusicTrack] = {
        guard let url = Bundle.main.url(forResource: "tracks", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [] }
        return file.tracks.filter { $0.url != nil }
    }()

    static var defaultTrack: MusicTrack? { tracks.first }

    static func track(id: String) -> MusicTrack? {
        tracks.first { $0.id == id }
    }

    /// The first song made for a style, else the default.
    static func suggestion(for style: StyleID) -> MusicTrack? {
        tracks.first { $0.suits(style) } ?? defaultTrack
    }
}
