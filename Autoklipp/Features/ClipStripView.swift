import AVFoundation
import ClipCore
import SwiftUI
import UIKit

/// The row of clips under the player (F11): drag to reorder, swipe up to remove, and lock clips
/// that must stay. Every action is also available from the context menu and to VoiceOver.
struct ClipStripView: View {
    let clips: [EDLClip]
    let media: [String: ImportedMedia]
    let currentTime: Double
    let isBusy: Bool
    let onSelect: (EDLClip) -> Void
    let onEdit: (ClipEdit) -> Void
    /// The duration label under each tile grows with Dynamic Type; the tile itself does not.
    @ScaledMetric(relativeTo: .caption2) private var labelHeight: CGFloat = 17
    @State private var userScrolling = false
    @State private var userScrolledAt = Date.distantPast
    /// Tiles a dragged clip is over; the strip holds still under the finger meanwhile.
    @State private var dropTargetIDs: Set<String> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        tile(clip, index: index)
                            .id(clip.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .onScrollPhaseChange { _, phase in
                let byUser: Bool
                switch phase {
                case .tracking, .interacting, .decelerating: byUser = true
                default: byUser = false
                }
                if byUser || userScrolling { userScrolledAt = .now }
                userScrolling = byUser
            }
            .onChange(of: playingClipID) { _, id in
                // The strip follows the film, but not while the user is looking for a clip.
                guard let id, !userScrolling, dropTargetIDs.isEmpty, Date.now.timeIntervalSince(userScrolledAt) > 3 else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 75 + labelHeight)
        .opacity(isBusy ? 0.6 : 1)
        .allowsHitTesting(!isBusy)
    }

    private var playingClipID: String? {
        clips.last { $0.timelineStart <= currentTime + 0.01 }?.id
    }

    /// Hands an edit on unless one is still being made; VoiceOver actions bypass hit testing.
    private func edit(_ edit: ClipEdit) {
        guard !isBusy else { return }
        onEdit(edit)
    }

    private func tile(_ clip: EDLClip, index: Int) -> some View {
        ClipTile(clip: clip, media: media[clip.mediaID], isPlaying: clip.id == playingClipID)
            .onTapGesture { onSelect(clip) }
            .draggable(clip.id) {
                ClipTile(clip: clip, media: media[clip.mediaID], isPlaying: false)
                    .frame(width: 64, height: 84)
            }
            .dropDestination(for: String.self) { ids, _ in
                dropTargetIDs = []
                guard !isBusy, let id = ids.first, id != clip.id else { return false }
                edit(.move(clipID: id, toIndex: index))
                return true
            } isTargeted: { targeted in
                if targeted { dropTargetIDs.insert(clip.id) } else { dropTargetIDs.remove(clip.id) }
                userScrolledAt = .now
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    // A clear upward swipe removes the clip; sideways drags scroll the strip.
                    if value.translation.height < -50, abs(value.translation.width) < abs(value.translation.height) {
                        edit(.remove(clipID: clip.id))
                    }
                }
            )
            .contextMenu {
                Button {
                    edit(.setLocked(clipID: clip.id, !clip.isLocked))
                } label: {
                    clip.isLocked ? Label("Unlock", systemImage: "lock.open") : Label("Lock", systemImage: "lock")
                }
                Button(role: .destructive) {
                    edit(.remove(clipID: clip.id))
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(clip, index: index))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: clip.isLocked ? Text("Unlock") : Text("Lock")) {
                edit(.setLocked(clipID: clip.id, !clip.isLocked))
            }
            .accessibilityAction(named: Text("Move earlier")) {
                if index > 0 { edit(.move(clipID: clip.id, toIndex: index - 1)) }
            }
            .accessibilityAction(named: Text("Move later")) {
                if index + 1 < clips.count { edit(.move(clipID: clip.id, toIndex: index + 1)) }
            }
            .accessibilityAction(named: Text("Remove")) {
                edit(.remove(clipID: clip.id))
            }
    }

    private func accessibilityLabel(_ clip: EDLClip, index: Int) -> Text {
        let kind = clip.kind == .video ? Text("Video") : Text("Photo")
        let base = Text("Clip \(index + 1) of \(clips.count)") + Text(verbatim: ", ") + kind + Text(verbatim: ", ")
            + Text(Formatting.duration(clip.duration))
        return clip.isLocked ? base + Text(verbatim: ", ") + Text("locked") : base
    }
}

/// One clip in the strip: a frame from the clip, its length and a lock badge.
struct ClipTile: View {
    let clip: EDLClip
    let media: ImportedMedia?
    let isPlaying: Bool
    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 3) {
            Color(uiColor: .secondarySystemBackground)
                .frame(width: 64, height: 64)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if clip.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.accentColor, in: .circle)
                            .padding(3)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isPlaying ? Color.accentColor : .clear, lineWidth: 3)
                }
            Text(Formatting.clock(clip.duration))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .task(id: clip.id) {
            guard let media else { return }
            image = await Self.frame(of: clip, media: media)
        }
    }

    /// A frame from inside the clip (videos) or the still itself.
    static func frame(of clip: EDLClip, media: ImportedMedia) async -> UIImage? {
        guard clip.kind == .video else { return await Thumbnailer.image(for: media, maxPixelSize: 160) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let time = CMTime(seconds: clip.sourceStart + min(0.3, clip.sourceDuration / 2), preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }
}
