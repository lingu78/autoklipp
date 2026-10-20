import AVFoundation
import ClipCore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var analysingSong = false

    var body: some View {
        List {
            StylePickerSection(draft: model.draft)
            MusicPickerSection(draft: model.draft, analysingSong: $analysingSong)
            SoundSection(draft: model.draft)
        }
        .navigationTitle("Style and music")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                model.path.append(.generate)
            } label: {
                Label("Create film", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(analysingSong)
            .padding()
            .background(.bar)
        }
    }
}

/// The styles to choose from.
struct StylePickerSection: View {
    let draft: ProjectDraft

    var body: some View {
        Section("Style") {
            ForEach(StyleID.allCases, id: \.self) { style in
                Button {
                    draft.select(style: style)
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
    }
}

/// The original-sound switch (F10).
struct SoundSection: View {
    @Bindable var draft: ProjectDraft

    var body: some View {
        Section {
            Toggle(isOn: $draft.originalAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sound from the videos")
                    Text("The music is lowered while people talk or cheer.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Built-in songs (those made for the style first), previews and the user's own file.
struct MusicPickerSection: View {
    let draft: ProjectDraft
    @Binding var analysingSong: Bool
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playingSongID: String?
    @State private var importingSong = false
    @State private var songMessage: String?

    var body: some View {
        Section {
            if let custom = draft.customSong {
                songRow(id: custom.id, title: Text(custom.title), detail: Text("\(Int(custom.info.bpm.rounded())) BPM · own file"), url: custom.url, start: 0)
            }
            ForEach(orderedTracks) { track in
                songRow(
                    id: track.id, title: Text(track.title),
                    detail: track.suits(draft.style) ? Text("\(Int(track.bpm)) BPM · suits the style") : Text("\(Int(track.bpm)) BPM"),
                    url: track.url, start: track.loopStart
                )
            }
            Button {
                importingSong = true
            } label: {
                if analysingSong {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding the beat…")
                    }
                } else {
                    Label("Use your own audio file…", systemImage: "music.note.list")
                }
            }
            .disabled(analysingSong)
        } header: {
            Text("Music")
        } footer: {
            if let songMessage {
                Text(songMessage)
            } else {
                Text("All built-in music is made for Autoklipp and free to use in your films.")
            }
        }
        .fileImporter(isPresented: $importingSong, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result {
                Task { await importSong(from: url) }
            }
        }
        .onDisappear(perform: stopPreview)
    }

    /// Songs made for the current style first.
    private var orderedTracks: [MusicTrack] {
        let style = draft.style
        return MusicCatalog.tracks.filter { $0.suits(style) } + MusicCatalog.tracks.filter { !$0.suits(style) }
    }

    private func songRow(id: String, title: Text, detail: Text, url: URL?, start: Double) -> some View {
        let selected = draft.musicTrackID == id
        return HStack {
            Button {
                draft.select(songID: id)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        title.font(.headline)
                        detail.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if let url {
                Button {
                    togglePreview(id: id, url: url, start: start)
                } label: {
                    Image(systemName: playingSongID == id ? "stop.circle" : "play.circle")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(playingSongID == id ? Text("Stop preview") : Text("Play preview"))
            }
        }
    }

    private func togglePreview(id: String, url: URL, start: Double) {
        if playingSongID == id {
            stopPreview()
            return
        }
        stopPreview()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.currentTime = start
        player.play()
        previewPlayer = player
        playingSongID = id
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
        playingSongID = nil
    }

    /// Copies the file into the project and finds its beat.
    private func importSong(from url: URL) async {
        analysingSong = true
        songMessage = nil
        defer { analysingSong = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let folder = draft.storage.musicDirectory
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = "custom-\(UUID().uuidString)"
            let copy = folder.appending(path: "\(id).\(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)")
            try FileManager.default.copyItem(at: url, to: copy)
            let info = try await AudioAnalyzer.trackInfo(id: id, url: copy)
            draft.customSong = SongChoice(
                id: id, title: url.deletingPathExtension().lastPathComponent, url: copy, info: info, isCustom: true
            )
            draft.select(songID: id)
        } catch AudioAnalyzer.AnalysisError.noBeat {
            songMessage = String(localized: "No steady beat was found in that song. Try another one.")
        } catch {
            songMessage = String(localized: "That file could not be read. Songs bought in Apple Music are protected and cannot be used.")
        }
    }
}
