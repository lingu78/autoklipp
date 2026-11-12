import AVFoundation
import SwiftUI
import UIKit
import VideoToolbox

/// Shows the film from frames pulled from its player, where a player layer cannot show it (see
/// PreviewSession.frameOutput). The player and its sound are the same; only the drawing differs,
/// so the film's own controls are a play and pause button over it, and the clip strip to move in it.
struct PulledFramePlayer: UIViewRepresentable {
    let output: AVPlayerItemVideoOutput
    let frames: DrawnFrames

    func makeUIView(context: Context) -> PulledFrameView {
        let view = PulledFrameView(frames: frames)
        view.output = output
        return view
    }

    func updateUIView(_ view: PulledFrameView, context: Context) {
        view.output = output
    }

    static func dismantleUIView(_ view: PulledFrameView, coordinator: ()) {
        view.stop()
    }
}

/// The frame last drawn, kept by the film's session: a view made for the other layout shows it at
/// once, also while the film is paused and no new frame comes.
@MainActor
final class DrawnFrames {
    var last: CGImage?
}

/// Draws the newest frame on each screen refresh while it is in a window.
final class PulledFrameView: UIView {
    var output: AVPlayerItemVideoOutput?
    /// Frames drawn so far; the tests check that the film is really drawn.
    private(set) var framesDrawn = 0
    private let frames: DrawnFrames
    private var link: CADisplayLink?

    init(frames: DrawnFrames) {
        self.frames = frames
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        layer.contents = frames.last
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(drawNewFrame))
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

    @objc private func drawNewFrame() {
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image else { return }
        layer.contents = image
        frames.last = image
        framesDrawn += 1
    }
}
