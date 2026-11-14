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

    /// The style's card: colours that say what the style does, dark enough for white text.
    var gradient: LinearGradient {
        let colors: [Color] = switch self {
        case .calm: [Color(red: 0.30, green: 0.60, blue: 0.58), Color(red: 0.13, green: 0.36, blue: 0.43)]
        case .energetic: [Color(red: 0.96, green: 0.45, blue: 0.16), Color(red: 0.80, green: 0.10, blue: 0.30)]
        case .nostalgic: [Color(red: 0.70, green: 0.50, blue: 0.32), Color(red: 0.42, green: 0.26, blue: 0.20)]
        case .travel: [Color(red: 0.20, green: 0.56, blue: 0.92), Color(red: 0.13, green: 0.30, blue: 0.72)]
        case .cinematic: [Color(red: 0.24, green: 0.28, blue: 0.38), Color(red: 0.04, green: 0.05, blue: 0.09)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Step 3: choose a style and a song.
struct StyleView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            StyleSections(draft: model.draft, describing: model.directorAvailable)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Style and music")
        .navigationBarTitleDisplayMode(.inline)
        .flowActions([
            FlowAction("Create film", systemImage: "wand.and.stars", kind: .primary, isDisabled: model.draft.analysingSong) {
                model.createFilm()
            },
        ])
    }
}

/// The description (with Apple Intelligence), style, music and sound sections of a list.
struct StyleSections: View {
    let draft: ProjectDraft
    let describing: Bool

    var body: some View {
        if describing {
            DescriptionSection(draft: draft)
        }
        StylePickerSection(draft: draft)
        MusicPickerSection(draft: draft)
        SoundSection(draft: draft)
    }
}

/// The styles to choose from, as a row of cards in the style's own colours.
struct StylePickerSection: View {
    let draft: ProjectDraft

    var body: some View {
        Section("Style") {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(StyleID.allCases, id: \.self) { style in
                            StyleCard(style: style, isSelected: draft.style == style) {
                                withAnimation(.snappy) { draft.choose(style: style) }
                            }
                            .id(style)
                        }
                    }
                    .padding(.vertical, 8)
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .onAppear { proxy.scrollTo(draft.style, anchor: .center) }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .sensoryFeedback(.selection, trigger: draft.style)
        }
    }
}

/// One style: its symbol, name and what it does, on the style's colours.
private struct StyleCard: View {
    let style: StyleID
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: style.symbol)
                    .font(.title.weight(.semibold))
                    .symbolEffect(.bounce, value: isSelected)
                Spacer(minLength: 8)
                Text(style.title)
                    .font(.headline)
                Text(style.summary)
                    .font(.caption)
                    .opacity(0.88)
                    .lineLimit(3, reservesSpace: true)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: 152, height: 184, alignment: .leading)
            .background(style.gradient, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(isSelected ? 0.95 : 0), lineWidth: 3)
                    .padding(4)
            }
            .shadow(color: .black.opacity(isSelected ? 0.25 : 0.08), radius: isSelected ? 12 : 4, y: isSelected ? 6 : 2)
            .scaleEffect(isSelected ? 1 : 0.95)
            .saturation(isSelected ? 1 : 0.8)
        }
        .buttonStyle(PressScale())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The free-text description for the AI director (F16), shown only with Apple Intelligence.
struct DescriptionSection: View {
    @Bindable var draft: ProjectDraft
    @FocusState private var isEditing: Bool

    var body: some View {
        Section {
            TextField(
                "For example: a calm film about the summer, focusing on the children",
                text: $draft.instruction, axis: .vertical
            )
            .lineLimit(2...4)
            .focused($isEditing)
            // A sentence or two: Return finishes it and puts the keyboard away, instead of
            // starting a new line under which the keyboard would stay until the film is made.
            .submitLabel(.done)
            .onChange(of: draft.instruction) { _, text in
                guard text.contains("\n") else { return }
                draft.instruction = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                isEditing = false
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditing = false }
                        .fontWeight(.semibold)
                }
            }
        } header: {
            Text("Describe your film (optional)")
        } footer: {
            Text("Apple Intelligence picks and orders the clips on your device. Only short descriptions of the clips are used, never the pictures.")
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

/// Built-in songs (those made for the style, then the rest behind More songs), previews and the
/// user's own file.
struct MusicPickerSection: View {
    let draft: ProjectDraft
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playingSongID: String?
    @State private var importingSong = false
    @State private var showsOtherSongs = false

    var body: some View {
        Section {
            if let custom = draft.customSong {
                songRow(id: custom.id, title: Text(custom.title), detail: Text("\(Int(custom.info.bpm.rounded())) BPM · own file"), url: custom.url, start: 0)
            }
            ForEach(suitedTracks) { track in
                songRow(id: track.id, title: Text(track.title), detail: Text("\(Int(track.bpm)) BPM · suits the style"), url: track.url, start: track.loopStart)
            }
            if !otherTracks.isEmpty {
                // The other songs stay out of the way until asked for, or while one of them is chosen.
                let otherChosen = otherTracks.contains { $0.id == draft.musicTrackID }
                if showsOtherSongs || otherChosen {
                    ForEach(otherTracks) { track in
                        songRow(id: track.id, title: Text(track.title), detail: Text("\(Int(track.bpm)) BPM"), url: track.url, start: track.loopStart)
                    }
                }
                if !otherChosen {
                    Button {
                        withAnimation(.snappy) { showsOtherSongs.toggle() }
                    } label: {
                        if showsOtherSongs {
                            Label("Fewer songs", systemImage: "chevron.up")
                        } else {
                            Label("More songs (\(otherTracks.count))", systemImage: "chevron.down")
                        }
                    }
                }
            }
            Button {
                importingSong = true
            } label: {
                if draft.analysingSong {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding the beat…")
                    }
                } else {
                    Label("Use your own audio file…", systemImage: "music.note.list")
                }
            }
            .disabled(draft.analysingSong)
        } header: {
            Text("Music")
        } footer: {
            if let songMessage = draft.songMessage {
                Text(songMessage)
            } else {
                Text("All built-in music is made for Autoklipp and free to use in your films.")
            }
        }
        .sensoryFeedback(.selection, trigger: draft.musicTrackID)
        .fileImporter(isPresented: $importingSong, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result {
                Task { await draft.importSong(from: url) }
            }
        }
        .task(id: playingSongID) {
            // A preview stops by itself at the end of the song.
            while !Task.isCancelled, let player = previewPlayer {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled, previewPlayer === player, !player.isPlaying { stopPreview() }
            }
        }
        .onDisappear(perform: stopPreview)
    }

    /// Songs made for the current style.
    private var suitedTracks: [MusicTrack] {
        MusicCatalog.tracks.filter { $0.suits(draft.style) }
    }

    private var otherTracks: [MusicTrack] {
        MusicCatalog.tracks.filter { !$0.suits(draft.style) }
    }

    private func songRow(id: String, title: Text, detail: Text, url: URL?, start: Double) -> some View {
        let selected = draft.musicTrackID == id
        return HStack {
            Button {
                withAnimation(.snappy) { draft.select(songID: id) }
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
}
