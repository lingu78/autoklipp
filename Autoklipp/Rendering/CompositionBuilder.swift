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
/// transitions; each clip is extended by half of each transition on either side when the
/// source has footage to spare. Stills have no track: the compositor draws them.
enum CompositionBuilder {
    enum BuildError: Error {
        case emptyEdit
        case trackCreationFailed
        case missingVideoTrack(String)
    }

    private struct VideoSource {
        let track: AVAssetTrack
        let duration: Double
        let orientation: CGImagePropertyOrientation
    }

    static func build(_ inputs: RenderInputs) async throws -> BuiltComposition {
        let edl = inputs.edl
        guard !edl.clips.isEmpty, edl.duration > 0 else { throw BuildError.emptyEdit }
        let composition = AVMutableComposition()
        let total = time(edl.duration)

        // Carrier track spanning the whole film.
        let blankAsset = AVURLAsset(url: try await BlankVideo.shared.url())
        guard let blankTrack = try await blankAsset.loadTracks(withMediaType: .video).first,
            let carrier = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.trackCreationFailed }
        let blankDuration = try await blankAsset.load(.duration)
        try carrier.insertTimeRange(CMTimeRange(start: .zero, duration: blankDuration), of: blankTrack, at: .zero)
        carrier.scaleTimeRange(CMTimeRange(start: .zero, duration: blankDuration), toDuration: total)

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
                    let duration = try await asset.load(.duration).seconds
                    let transform = try await track.load(.preferredTransform)
                    source = VideoSource(track: track, duration: duration, orientation: CGImagePropertyOrientation(videoTransform: transform))
                    sources[clip.mediaID] = source
                }

                // Half of each neighbouring transition, where the source has footage for it.
                let rate = clip.playbackRate
                let wantedBefore = clip.transitionIn.duration / 2
                let wantedAfter = index + 1 < edl.clips.count ? edl.clips[index + 1].transitionIn.duration / 2 : 0
                let before = max(0, min(wantedBefore, clip.sourceStart / rate))
                let after = max(0, min(wantedAfter, (source.duration - clip.sourceEnd) / rate))
                let sourceStart = max(0, clip.sourceStart - before * rate)
                let sourceEnd = min(source.duration, clip.sourceEnd + after * rate)
                let compositionStart = max(0, clip.timelineStart - before)
                let compositionEnd = min(edl.duration, clip.timelineEnd + after)
                guard sourceEnd - sourceStart > 0.01, compositionEnd - compositionStart > 0.01 else { continue }

                let track = try videoTrack(videoCount % 2)
                videoCount += 1
                let sourceRange = CMTimeRange(start: time(sourceStart), end: time(sourceEnd))
                try track.insertTimeRange(sourceRange, of: source.track, at: time(compositionStart))
                let wanted = time(compositionEnd - compositionStart)
                if CMTimeCompare(sourceRange.duration, wanted) != 0 {
                    track.scaleTimeRange(CMTimeRange(start: time(compositionStart), duration: sourceRange.duration), toDuration: wanted)
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
                let musicDuration = try await musicAsset.load(.duration).seconds
                for segment in cue.segments {
                    let start = segment.filmStart
                    let length = min(segment.duration, edl.duration - start, musicDuration - segment.trackStart)
                    guard length > 0.01 else { continue }
                    try track.insertTimeRange(
                        CMTimeRange(start: time(segment.trackStart), duration: time(length)), of: musicTrack, at: time(start)
                    )
                }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                let volume = Float(cue.volume)
                parameters.setVolume(volume, at: .zero)
                let fade = min(cue.fadeOut, edl.duration / 2)
                if fade > 0 {
                    parameters.setVolumeRamp(
                        fromStartVolume: volume, toEndVolume: 0,
                        timeRange: CMTimeRange(start: time(edl.duration - fade), end: total)
                    )
                }
                audioParameters.append(parameters)
            }
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParameters

        let renderSize = inputs.settings.renderSize
        let timeline = RenderTimeline(renderSize: renderSize, duration: edl.duration, layers: layers)
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
