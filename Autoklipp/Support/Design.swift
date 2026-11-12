import SwiftUI

// The app's look, shared by every screen: the icon's warm colours, its mark, the drifting
// gradient behind the start screen and the making of a film, and the dark stage films are shown
// on. Screens reach to the edges of the display; only their content keeps to the safe area.

/// Colours of the app icon's gradient.
enum Brand {
    static let orange = Color(red: 238 / 255, green: 110 / 255, blue: 64 / 255)
    static let coral = Color(red: 232 / 255, green: 82 / 255, blue: 82 / 255)
    static let raspberry = Color(red: 214 / 255, green: 54 / 255, blue: 107 / 255)
    static let deep = Color(red: 176 / 255, green: 32 / 255, blue: 100 / 255)
    static let plum = Color(red: 128 / 255, green: 24 / 255, blue: 90 / 255)

    /// The icon's diagonal, for marks and badges.
    static let diagonal = LinearGradient(colors: [coral, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The icon's mark: three stacked frames with a play symbol. `spread` fans the frames out
/// from a single stack (0) to the icon's layout (1).
struct AutoklippMark: View {
    let size: CGFloat
    let spread: CGFloat

    var body: some View {
        ZStack {
            frame(opacity: 0.3, step: 2)
            frame(opacity: 0.55, step: 1)
            frame(opacity: 1, step: 0)
                .overlay {
                    PlayTriangle()
                        .fill(Brand.raspberry)
                        .frame(width: size * 0.166, height: size * 0.186)
                        .offset(x: size * (-0.051 + 0.015), y: size * 0.076)
                }
                .shadow(color: .black.opacity(0.18), radius: size * 0.03, y: size * 0.015)
        }
        .frame(width: size, height: size)
    }

    /// As in the icon: the front frame sits left of and below the centre, and each frame
    /// behind it is a step up and to the right.
    private func frame(opacity: Double, step: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.047, style: .continuous)
            .fill(.white.opacity(opacity))
            .frame(width: size * 0.508, height: size * 0.352)
            .offset(x: size * (-0.051 + 0.049 * step * spread), y: size * (0.076 - 0.078 * step * spread))
    }
}

struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The icon's warm gradient, drifting slowly unless motion is reduced.
struct HeroBackground: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let dx = Float(animated ? 0.12 * sin(time * 0.35) : 0)
            let dy = Float(animated ? 0.08 * cos(time * 0.27) : 0)
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + dx, 0.5 + dy], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Brand.orange, Brand.orange, Brand.coral,
                    Brand.coral, Brand.raspberry, Brand.deep,
                    Brand.raspberry, Brand.deep, Brand.plum,
                ]
            )
        }
    }
}

/// Shrinks a little while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The dark stage a film is shown on, reaching under the bars and to every edge of the display,
/// so that the film itself is the brightest thing on screen.
struct FilmStage: View {
    var body: some View {
        Color.black.ignoresSafeArea()
    }
}
