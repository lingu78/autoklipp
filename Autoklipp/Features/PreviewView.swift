import AVKit
import ClipCore
import SwiftUI

/// Step 5: watch the film and adjust it.
struct PreviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showingExport = false

    var body: some View {
        VStack(spacing: 16) {
            if let session = model.preview {
                VideoPlayer(player: session.player)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel(Text("Film preview"))
                    .onAppear { session.player.play() }
                    .onDisappear { session.player.pause() }

                ForEach(Array(session.edl.notices.enumerated()), id: \.offset) { _, notice in
                    noticeView(notice)
                }

                HStack(spacing: 6) {
                    Text(Formatting.duration(session.edl.duration))
                    Text(verbatim: "·")
                    Text("\(session.edl.clips.count) clips")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                ContentUnavailableView("No film yet", systemImage: "film")
            }
            Spacer(minLength: 0)
            actions
        }
        .padding()
        .navigationTitle("Your film")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingExport) {
            if let session = model.preview {
                ExportView(edl: session.edl, draft: model.draft)
            }
        }
    }

    private var aspectRatio: CGFloat {
        let size = RenderSettings.preview(model.draft.format).renderSize
        return size.width / size.height
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    regenerate()
                } label: {
                    Label("Another version", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    changeStyle()
                } label: {
                    Label("Style and music", systemImage: "paintpalette")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Button {
                model.preview?.player.pause()
                showingExport = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.preview == nil)
        }
    }

    @ViewBuilder
    private func noticeView(_ notice: PlanNotice) -> some View {
        switch notice {
        case let .materialShorterThanTarget(available, target):
            Label(
                "There was only enough material for \(Formatting.duration(available)) of the \(Formatting.duration(target)) you asked for.",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func regenerate() {
        model.preview?.player.pause()
        model.draft.seed = UInt64.random(in: 1...UInt64.max)
        if model.path.last == .preview { model.path.removeLast() }
        model.path.append(.generate)
    }

    private func changeStyle() {
        model.preview?.player.pause()
        if let index = model.path.lastIndex(of: .style) {
            model.path.removeSubrange((index + 1)...)
        } else {
            model.path.append(.style)
        }
    }
}
