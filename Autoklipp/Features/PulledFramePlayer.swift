import AVFoundation
import SwiftUI
import UIKit

/// Shows the film from frames the app reads itself (see PreviewSession.frames), in step with the
/// player that plays its sound. The film's own controls are a play and pause button over it, and
/// the clip strip to move in it.
struct PulledFramePlayer: UIViewRepresentable {
    let frames: ComposedFrames
    let player: AVPlayer

    func makeUIView(context: Context) -> PulledFrameView {
        let view = PulledFrameView()
        view.show(frames, player: player)
        return view
    }

    func updateUIView(_ view: PulledFrameView, context: Context) {
        view.show(frames, player: player)
    }

    static func dismantleUIView(_ view: PulledFrameView, coordinator: ()) {
        view.stop()
    }
}

/// Draws the frame for the player's time on each screen refresh while it is in a window.
final class PulledFrameView: UIView {
    private var frames: ComposedFrames?
    private var player: AVPlayer?
    /// Frames drawn so far; the tests check that the film is really drawn.
    private(set) var framesDrawn = 0
    private var link: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ frames: ComposedFrames, player: AVPlayer) {
        if self.frames !== frames {
            self.frames = frames
            // A view made for the other layout shows the frame shown last at once, also while
            // the film is paused; a new film keeps it until its own frames come.
            if let image = frames.lastImage { layer.contents = image }
        }
        self.player = player
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(drawFrame))
        // The preview is made at 30 frames per second.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Also breaks the display link's hold on the view.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func drawFrame() {
        guard let frames, let player else { return }
        let time = player.currentTime().seconds
        guard time.isFinite, let image = frames.newImage(at: time) else { return }
        layer.contents = image
        framesDrawn += 1
    }
}
