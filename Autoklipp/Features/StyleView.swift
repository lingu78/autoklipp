import AVFoundation
import ClipCore
import SwiftUI

extension StyleID {
    var title: LocalizedStringResource {
        switch self {
        case .calm: "Calm"
        case .energetic: "Energetic"
        case .nostalgic: "Nostalgic"
        case .travel: "Travel"
        case .cinematic: "Cinematic"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .calm: "Long, soft crossfades and gentle colours."
        case .energetic: "Fast cuts on every beat and punchy colours."
        case .nostalgic: "Faded film look with warm white flashes."
        case .travel: "Lively pace, slides and warm light."
        case .cinematic: "Unhurried, dark fades and a cinema grade."
        }
    }

    var symbol: String {
        switch self {
        case .calm: "leaf"
        case .energetic: "bolt.fill"
        case .nostalgic: "camera.filters"
        case .travel: "airplane"
        case .cinematic: "film"
        }
    }
}

/// Step 3: choose a style and a song.
struct StyleView: View {
    @Environment(AppModel.self) private var model
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playingTrackID: String?

    private var draft: ProjectDraft { model.draft }

    var body: some View {
        List {
            Section("Style") {
                ForEach(StyleID.allCases, id: \.self) { style in
                    Button {
                        draft.style = style
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: style.symbol)
                                .font(.title2)
                                .frame(width: 36)
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(style.title).font(.headline)
                                Text(style.summary).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if draft.style == style {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(draft.style == style ? .isSelected : [])
                }
            }

            Section {
                ForEach(MusicCatalog.tracks) { track in
                    HStack {
                        Button {
                            draft.musicTrackID = track.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).font(.headline)
                                    Text("\(Int(track.bpm)) BPM").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if draft.musicTrackID == track.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.musicTrackID == track.id ? .isSelected : [])

                        Button {
                            togglePreview(track)
                        } label: {
                            Image(systemName: playingTrackID == track.id ? "stop.circle" : "play.circle")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(playingTrackID == track.id ? Text("Stop preview") : Text("Play preview of \(track.title)"))
                    }
                }
            } header: {
                Text("Music")
            } footer: {
                Text("All built-in music is made for Autoklipp and free to use in your films.")
            }
        }
        .navigationTitle("Style and music")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                stopPreview()
                model.path.append(.generate)
            } label: {
                Label("Create film", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .background(.bar)
        }
        .onDisappear(perform: stopPreview)
    }

    private func togglePreview(_ track: MusicTrack) {
        if playingTrackID == track.id {
            stopPreview()
            return
        }
        stopPreview()
        guard let url = track.url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.currentTime = track.loopStart
        player.play()
        previewPlayer = player
        playingTrackID = track.id
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        playingTrackID = nil
    }
}
