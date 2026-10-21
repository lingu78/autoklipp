import AVFoundation
import ClipCore
import Foundation
import ImageIO

/// Everything needed to play or export a film.
struct BuiltComposition: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    let duration: Double

    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        // Slightly retimed original sound keeps its pitch, as in the export.
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

/// What the builder needs besides the clip list.
struct RenderInputs: Sendable {
    var edl: EditDecisionList
    var media: [String: ImportedMedia]
    var musicURL: URL?
    var settings: RenderSettings
}

/// Turns a clip list into an AVFoundation composition. Rendering always starts here, so any
/// change to the clip list is reflected by building again.
///
/// Video clips alternate between two tracks so that neighbours can overlap during
/// transitions; each clip is extended by half of each transition on either side, with footage
/// the source has to spare or else by holding its first or last frame. Stills have no track:
/// the compositor draws them.
enum CompositionBuilder {
    enum BuildError: LocalizedError {
        case emptyEdit
        case trackCreationFailed
        case missingVideoTrack(String)
        case insertFailed(String, any Error)

        var errorDescription: String? {
            switch self {
            case .emptyEdit: "empty clip list"
            case .trackCreationFailed: "could not add a composition track"
            case let .missingVideoTrack(id): "no video track in \(id)"
            case let .insertFailed(what, error): "inserting \(what) failed: \(error.localizedDescription) \(error)"
            }
        }
    }

    private struct VideoSource {
        /// Kept alive on purpose: a track only holds its asset weakly and stops working without it.
        let asset: AVURLAsset
        let track: AVAssetTrack
        /// Where the track has media, seconds; may differ from the file's duration.
        let start: Double
        let end: Double
        let orientation: CGImagePropertyOrientation
        /// The video's own sound, when it has any.
        let sound: AVAssetTrack?
        let soundRange: CMTimeRange
    }

    /// Applies a keyframe curve as volume ramps.
    private static func apply(_ keys: [VolumeKeyframe], to parameters: AVMutableAudioMixInputParameters) {
        guard let first = keys.first else { return }
        parameters.setVolume(Float(first.volume), at: time(first.time))
        for (from, to) in zip(keys, keys.dropFirst()) where to.time - from.time > 1e-3 {
            parameters.setVolumeRamp(
                fromStartVolume: Float(from.volume), toEndVolume: Float(to.volume),
                timeRange: CMTimeRange(start: time(from.time), end: time(to.time))
            )
        }
    }

    /// Inserts `start..<end` of a source track (clamped to where it has media) so that source
    /// time `start` lands at `at`. Returns the range of the target track it now fills.
    @discardableResult
    private static func insert(
        _ start: Double, _ end: Double, of track: AVAssetTrack, available: CMTimeRange,
        into target: AVMutableCompositionTrack, at: Double, what: @autoclosure () -> String
    ) throws -> CMTimeRange {
        let lower = CMTimeMaximum(time(start), available.start)
        let upper = CMTimeMinimum(time(end), available.end)
        let range = CMTimeRange(start: lower, end: upper)
        guard range.duration > .zero else { return CMTimeRange(start: time(at), duration: .zero) }
        // A clamped start trims the head of the media instead of moving it earlier. Media is
        // never inserted before the track's end: that would split what is there and push it
        // later (separately rounded pieces can overlap by a tick).
        let trackEnd = target.segments.last?.timeMapping.target.end ?? .zero
        let position = CMTimeMaximum(CMTimeAdd(time(at), CMTimeSubtract(lower, time(start))), trackEnd)
        // A track cannot take media after its end; fill the gap with an empty range first.
        if position > trackEnd {
            target.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: position))
        }
        do {
            try target.insertTimeRange(range, of: track, at: position)
        } catch {
            throw BuildError.insertFailed(
                "\(what()) [\(range.start.seconds)–\(range.end.seconds) of \(available.start.seconds)–\(available.end.seconds) at \(position.seconds)]",
                error
            )
        }
        return CMTimeRange(start: position, duration: range.duration)
    }

    /// Retimes what `insert` put into a track so that it lasts `duration`.
    private static func scale(_ inserted: CMTimeRange, of track: AVMutableCompositionTrack, to duration: CMTime) {
        guard inserted.duration > .zero, duration > .zero, CMTimeCompare(inserted.duration, duration) != 0 else { return }
        track.scaleTimeRange(inserted, toDuration: duration)
    }

    /// Cuts off whatever a track holds after `end`.
    private static func trim(_ track: AVMutableCompositionTrack, to end: CMTime) {
        let trackEnd = track.segments.last?.timeMapping.target.end ?? .zero
        if trackEnd > end {
            track.removeTimeRange(CMTimeRange(start: end, end: trackEnd))
        }
    }

    static func build(_ inputs: RenderInputs) async throws -> BuiltComposition {
        let edl = inputs.edl
        guard !edl.clips.isEmpty, edl.duration > 0 else { throw BuildError.emptyEdit }
        let composition = AVMutableComposition()
        let total = time(edl.duration)

        // Carrier track spanning the whole film.
        let blankURL = try await BlankVideo.shared.url()
        let blankAsset = AVURLAsset(url: blankURL)
        guard let blankTrack = try await blankAsset.loadTracks(withMediaType: .video).first,
            let carrier = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.trackCreationFailed }
        let blankRange = try await blankTrack.load(.timeRange)
        do {
            try carrier.insertTimeRange(blankRange, of: blankTrack, at: .zero)
        } catch {
            throw BuildError.insertFailed("carrier \(blankRange.start.seconds)–\(blankRange.end.seconds)", error)
        }
        carrier.scaleTimeRange(CMTimeRange(start: .zero, duration: blankRange.duration), toDuration: total)

        var videoTracks: [AVMutableCompositionTrack] = []
        func videoTrack(_ index: Int) throws -> AVMutableCompositionTrack {
            while videoTracks.count <= index {
                guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw BuildError.trackCreationFailed }
                videoTracks.append(track)
            }
            return videoTracks[index]
        }

        var sources: [String: VideoSource] = [:]
        var layers: [RenderTimeline.Layer] = []
        var videoCount = 0
        // The videos' own sound follows the same alternating tracks as the pictures.
        var soundTracks: [AVMutableCompositionTrack?] = [nil, nil]
        var soundKeys: [[VolumeKeyframe]] = [[], []]
        for (index, clip) in edl.clips.enumerated() {
            guard let media = inputs.media[clip.mediaID] else { continue }
            let content: RenderTimeline.Layer.Content
            if clip.kind == .video {
                let source: VideoSource
                if let cached = sources[clip.mediaID] {
                    source = cached
                } else {
                    let asset = AVURLAsset(url: media.url)
                    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                        throw BuildError.missingVideoTrack(clip.mediaID)
                    }
                    let (range, transform) = try await track.load(.timeRange, .preferredTransform)
                    let sound = try await asset.loadTracks(withMediaType: .audio).first
                    let soundRange = try await sound?.load(.timeRange) ?? .zero
                    source = VideoSource(
                        asset: asset, track: track, start: range.start.seconds, end: range.end.seconds,
                        orientation: CGImagePropertyOrientation(videoTransform: transform),
                        sound: sound, soundRange: soundRange
                    )
                    sources[clip.mediaID] = source
                }

                // Half of each neighbouring transition, from footage the source has to spare.
                // Where it has none, its first or last frame is held instead: an empty lane
                // would blend the neighbour with black.
                let rate = clip.playbackRate
                let wantedBefore = max(0, min(clip.transitionIn.duration / 2, clip.timelineStart))
                let nextTransition = index + 1 < edl.clips.count ? edl.clips[index + 1].transitionIn.duration / 2 : 0
                let wantedAfter = max(0, min(nextTransition, edl.duration - clip.timelineEnd))
                let before = max(0, min(wantedBefore, (clip.sourceStart - source.start) / rate))
                let after = max(0, min(wantedAfter, (source.end - clip.sourceEnd) / rate))
                let sourceStart = max(source.start, clip.sourceStart - before * rate)
                let sourceEnd = min(source.end, clip.sourceEnd + after * rate)
                let compositionStart = clip.timelineStart - before
                let compositionEnd = clip.timelineEnd + after
                guard sourceEnd - sourceStart > 0.01, compositionEnd - compositionStart > 0.01 else { continue }
                // How much the footage is stretched to fill its place in the film.
                let stretch = (compositionEnd - compositionStart) / (sourceEnd - sourceStart)

                let lane = videoCount % 2
                let track = try videoTrack(lane)
                videoCount += 1
                if clip.audioVolume > 0, let sound = source.sound, abs(clip.playbackRate - 1) < 0.05 {
                    if soundTracks[lane] == nil {
                        soundTracks[lane] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    if let soundTrack = soundTracks[lane] {
                        let inserted = try insert(
                            sourceStart, sourceEnd, of: sound, available: source.soundRange,
                            into: soundTrack, at: compositionStart, what: "sound of clip \(index)"
                        )
                        // Retimed like the picture, so it stays in sync with it.
                        scale(inserted, of: soundTrack, to: CMTimeMultiplyByFloat64(inserted.duration, multiplier: stretch))
                        soundKeys[lane] += AudioMixPlan.clipKeyframes(for: edl, clipIndex: index)
                    }
                }
                let available = CMTimeRange(start: time(source.start), end: time(source.end))
                let frame = 1 / Double(max(1, edl.frameRate))
                let holdBefore = wantedBefore - before
                if holdBefore >= frame / 2 {
                    let held = try insert(
                        sourceStart, min(sourceEnd, sourceStart + frame), of: source.track, available: available,
                        into: track, at: compositionStart - holdBefore, what: "first frame of clip \(index) (\(clip.mediaID))"
                    )
                    scale(held, of: track, to: CMTimeSubtract(time(compositionStart), held.start))
                }
                let inserted = try insert(
                    sourceStart, sourceEnd, of: source.track, available: available,
                    into: track, at: compositionStart, what: "clip \(index) (\(clip.mediaID))"
                )
                scale(inserted, of: track, to: CMTimeSubtract(time(compositionEnd), inserted.start))
                let holdAfter = wantedAfter - after
                if holdAfter >= frame / 2, inserted.duration > .zero {
                    let held = try insert(
                        max(sourceStart, sourceEnd - frame), sourceEnd, of: source.track, available: available,
                        into: track, at: compositionEnd, what: "last frame of clip \(index) (\(clip.mediaID))"
                    )
                    scale(held, of: track, to: CMTimeSubtract(time(compositionEnd + holdAfter), held.start))
                }
                content = .video(trackID: track.trackID, orientation: source.orientation)
            } else {
                content = .still(url: media.url, pixelWidth: media.item.pixelWidth, pixelHeight: media.item.pixelHeight)
            }
            layers.append(
                RenderTimeline.Layer(
                    content: content, mediaID: clip.mediaID, start: clip.timelineStart, end: clip.timelineEnd,
                    transitionIn: clip.transitionIn, filter: clip.filter, kenBurns: clip.kenBurns
                )
            )
        }

        // Music, cut to the film and faded out at the end.
        var audioParameters: [AVMutableAudioMixInputParameters] = []
        if let musicURL = inputs.musicURL, let cue = edl.music {
            let musicAsset = AVURLAsset(url: musicURL)
            if let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first,
                let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            {
                let available = try await musicTrack.load(.timeRange)
                for segment in cue.segments {
                    let start = segment.filmStart
                    let length = min(segment.duration, edl.duration - start)
                    guard length > 0.01 else { continue }
                    try insert(
                        segment.trackStart, segment.trackStart + length, of: musicTrack, available: available,
                        into: track, at: start, what: "music at \(start)"
                    )
                }
                trim(track, to: total)
                // Full volume, lowered under loud original sound, faded out at the end.
                let parameters = AVMutableAudioMixInputParameters(track: track)
                apply(AudioMixPlan.musicKeyframes(for: edl), to: parameters)
                audioParameters.append(parameters)
            }
        }
        for (lane, soundTrack) in soundTracks.enumerated() {
            guard let soundTrack else { continue }
            let parameters = AVMutableAudioMixInputParameters(track: soundTrack)
            apply(soundKeys[lane], to: parameters)
            audioParameters.append(parameters)
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters

        // Pieces rounded to 1/600 s one by one can end a tick or two after the film, but the
        // video composition's only instruction must cover the whole asset.
        for track in videoTracks + soundTracks.compactMap({ $0 }) {
            trim(track, to: total)
        }

        let renderSize = inputs.settings.renderSize
        let timeline = RenderTimeline(
            renderSize: renderSize, duration: edl.duration, layers: layers, title: edl.title, endCredit: edl.endCredit
        )
        let instruction = ClipInstruction(
            timeRange: CMTimeRange(start: .zero, duration: total),
            trackIDs: [carrier.trackID] + videoTracks.map(\.trackID),
            renderer: FrameRenderer(timeline: timeline)
        )
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = ClipCompositor.self
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, edl.frameRate)))
        videoComposition.renderSize = renderSize
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = [instruction]

        return BuiltComposition(
            composition: composition.copy() as? AVComposition ?? composition,
            videoComposition: videoComposition.copy() as? AVVideoComposition ?? videoComposition,
            audioMix: audioMix.copy() as? AVAudioMix ?? audioMix,
            duration: edl.duration
        )
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
