import SwiftUI

// iPhone Duo support. Built with the iOS 27.1 SDK (Xcode 27.1, Swift 6.4), the system puts
// navigation bars and toolbars on the side of the display on iPhone Duo's outer display, and on
// the inner display in landscape. Everything here that needs that SDK is behind
// `#if compiler(>=6.4)` and `#available(iOS 27.1, *)`, so the app still builds with Xcode 26 and
// runs as before on other iPhones.

/// An action of a step in the one-column layout.
struct FlowAction: Identifiable {
    enum Kind {
        /// Moves the flow on (Next, Create film, Export).
        case primary
        case secondary
        /// Leaves the step (Cancel, Back); first in a bar on the side.
        case cancel
        /// Throws work away (Start over); in the navigation bar, and last in a bar on the side.
        case destructive
    }

    let title: LocalizedStringKey
    let systemImage: String
    let kind: Kind
    let isDisabled: Bool
    let perform: () -> Void

    init(
        _ title: LocalizedStringKey, systemImage: String, kind: Kind = .secondary, isDisabled: Bool = false,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.isDisabled = isDisabled
        self.perform = perform
    }

    var id: String { systemImage }
}

extension View {
    /// Shows a step's actions where they fit best: as buttons under the content, or as items of
    /// the bars when the system shows those on the side, which leaves the height to the content.
    @ViewBuilder
    func flowActions(_ actions: [FlowAction]) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            modifier(SideAwareFlowActions(actions: actions))
        } else {
            modifier(BottomFlowActions(actions: actions))
        }
        #else
        modifier(BottomFlowActions(actions: actions))
        #endif
    }
}

/// Bars along the top and bottom: the actions as buttons under the content, as on any iPhone.
private struct BottomFlowActions: ViewModifier {
    let actions: [FlowAction]

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                FlowActionPanel(actions: actions.filter { $0.kind != .destructive })
            }
            .toolbar {
                let destructive = actions.filter { $0.kind == .destructive }
                if !destructive.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ForEach(destructive) { action in
                            Button(action.title, role: .destructive, action: action.perform)
                                .disabled(action.isDisabled)
                        }
                    }
                }
            }
    }
}

#if compiler(>=6.4)
/// Follows where the system puts the bars: under the content while they run along the top and
/// bottom, in the bars while those are on the side. Items there need both a title and a symbol.
@available(iOS 27.1, *)
private struct SideAwareFlowActions: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let actions: [FlowAction]

    func body(content: Content) -> some View {
        let onSide = verticalEdge != nil
        let cancel = actions.filter { $0.kind == .cancel }
        let primary = actions.filter { $0.kind == .primary }
        let secondary = actions.filter { $0.kind == .secondary }
        let destructive = actions.filter { $0.kind == .destructive }
        content
            .safeAreaInset(edge: .bottom) {
                if !onSide {
                    FlowActionPanel(actions: actions.filter { $0.kind != .destructive })
                }
            }
            .toolbar {
                if onSide {
                    // The standard order on the side: Back or Close first, then the prominent
                    // action, then the rest; Start over is the first to go to the overflow menu.
                    if !cancel.isEmpty {
                        ToolbarItemGroup(placement: .cancellationAction) {
                            ForEach(cancel) { SideBarButton(action: $0) }
                        }
                    }
                    if !primary.isEmpty {
                        ToolbarItemGroup(placement: .topBarPinnedTrailing) {
                            ForEach(primary) { SideBarButton(action: $0) }
                        }
                        .visibilityPriority(.high)
                    }
                    if !secondary.isEmpty {
                        ToolbarItemGroup(placement: .bottomBar) {
                            ForEach(secondary) { SideBarButton(action: $0) }
                        }
                    }
                    if !destructive.isEmpty {
                        ToolbarItemGroup(placement: .bottomBar) {
                            ForEach(destructive) { SideBarButton(action: $0) }
                        }
                        .visibilityPriority(.low)
                    }
                } else if !destructive.isEmpty {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ForEach(destructive) { action in
                            Button(action.title, role: .destructive, action: action.perform)
                                .disabled(action.isDisabled)
                        }
                    }
                }
            }
    }
}

@available(iOS 27.1, *)
private struct SideBarButton: View {
    let action: FlowAction

    var body: some View {
        Button(role: action.kind == .destructive ? .destructive : nil, action: action.perform) {
            Label(action.title, systemImage: action.systemImage)
        }
        .disabled(action.isDisabled)
    }
}
#endif

/// The actions as buttons under the content: the primary one prominent, the others in pairs.
struct FlowActionPanel: View {
    let actions: [FlowAction]

    var body: some View {
        if !actions.isEmpty {
            Group {
                if actions.count == 1, let action = actions.first {
                    button(action)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(actions.filter { $0.kind != .primary } + actions.filter { $0.kind == .primary }) { action in
                            button(action)
                        }
                    }
                }
            }
            .padding()
            .background(.bar)
        }
    }

    @ViewBuilder
    private func button(_ action: FlowAction) -> some View {
        if action.kind == .primary {
            Button(action: action.perform) {
                label(action)
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(action.isDisabled)
        } else {
            Button(role: action.kind == .cancel ? .cancel : nil, action: action.perform) {
                label(action)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(action.isDisabled)
        }
    }

    private func label(_ action: FlowAction) -> some View {
        Label(action.title, systemImage: action.systemImage)
            .frame(maxWidth: .infinity)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}

extension GeometryProxy {
    /// The fold while the display is partly folded like a book (the fold runs from top to
    /// bottom), as a band of x positions in this view. Nil when the display is flat or open, for
    /// a fold across the view, and before iOS 27.1.
    var verticalFold: ClosedRange<CGFloat>? {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            for region in reservedRegions(kind: .division) where region.isActive {
                let frame = region.frame
                if frame.height > frame.width, frame.minX > 0, frame.maxX < size.width {
                    return frame.minX...frame.maxX
                }
            }
        }
        #endif
        return nil
    }
}
