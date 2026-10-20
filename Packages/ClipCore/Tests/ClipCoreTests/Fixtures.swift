import Foundation
import Testing

@testable import ClipCore

/// Builders for synthetic material used across the tests.
enum Fixtures {
    static let baseDate = Date(timeIntervalSince1970: 1_750_000_000)

    /// Stills and videos interleaved, one minute apart, in a shuffled pick order.
    static func mixedMedia(photos: Int, videoDurations: [Double], shuffleSeed: UInt64 = 1) -> [MediaItem] {
        var items: [MediaItem] = []
        var minute = 0
        var photoCount = 0
        var videoIndex = 0
        while photoCount < photos || videoIndex < videoDurations.count {
            if photoCount < photos {
                items.append(
                    MediaItem(
                        id: "photo-\(photoCount)", kind: .photo,
                        creationDate: baseDate.addingTimeInterval(Double(minute) * 60)
                    )
                )
                photoCount += 1
                minute += 1
            }
            if videoIndex < videoDurations.count {
                items.append(
                    MediaItem(
                        id: "video-\(videoIndex)", kind: .video,
                        creationDate: baseDate.addingTimeInterval(Double(minute) * 60),
                        duration: videoDurations[videoIndex], hasAudio: true
                    )
                )
                videoIndex += 1
                minute += 1
            }
        }
        var rng = SeededGenerator(seed: shuffleSeed)
        return items.shuffled(using: &rng)
    }

    static func request(
        media: [MediaItem],
        target: Double,
        style: StyleID = .travel,
        bpm: Double = 120,
        seed: UInt64 = 7,
        analyses: [String: MediaAnalysis] = [:]
    ) -> PlanningRequest {
        let track = TrackInfo.metronome(bpm: bpm, duration: 240)
        return PlanningRequest(
            media: media,
            analyses: analyses,
            targetDuration: target,
            style: .preset(style),
            music: MusicLayout.make(track: track, filmDuration: target),
            musicTrackID: track.id,
            seed: seed
        )
    }

    /// Analysis where every segment of a video has the same metrics.
    static func uniformVideo(_ item: MediaItem, _ metrics: FrameMetrics) -> MediaAnalysis {
        let count = Int((item.duration / Timing.segmentLength).rounded(.up))
        return MediaAnalysis(
            mediaID: item.id,
            segments: (0..<count).map {
                SegmentAnalysis(start: Double($0) * Timing.segmentLength, duration: Timing.segmentLength, metrics: metrics)
            }
        )
    }
}

/// Invariants every clip list must satisfy.
func expectWellFormed(_ edl: EditDecisionList, media: [MediaItem], sourceLocation: SourceLocation = #_sourceLocation) {
    let byID = Dictionary(uniqueKeysWithValues: media.map { ($0.id, $0) })
    var time = 0.0
    var ids = Set<String>()
    for clip in edl.clips {
        #expect(abs(clip.timelineStart - time) < 1e-6, "clips must be contiguous", sourceLocation: sourceLocation)
        #expect(clip.duration > 0, sourceLocation: sourceLocation)
        #expect(ids.insert(clip.id).inserted, "clip ids must be unique", sourceLocation: sourceLocation)
        time = clip.timelineEnd
        guard let item = byID[clip.mediaID] else {
            Issue.record("unknown media \(clip.mediaID)", sourceLocation: sourceLocation)
            continue
        }
        if item.kind == .video {
            #expect(clip.sourceStart >= -1e-9, sourceLocation: sourceLocation)
            #expect(clip.sourceEnd <= item.duration + 1e-6, "in/out points inside the source", sourceLocation: sourceLocation)
        }
    }
    #expect(abs(time - edl.duration) < 1e-6, sourceLocation: sourceLocation)
    // No two clips of the same video may show the same footage.
    let videoClips = Dictionary(grouping: edl.clips.filter { $0.kind == .video }, by: \.mediaID)
    for (_, clips) in videoClips {
        let sorted = clips.sorted { $0.sourceStart < $1.sourceStart }
        for (lhs, rhs) in zip(sorted, sorted.dropFirst()) {
            #expect(lhs.sourceEnd <= rhs.sourceStart + 1e-6, "footage repeated", sourceLocation: sourceLocation)
        }
    }
}
