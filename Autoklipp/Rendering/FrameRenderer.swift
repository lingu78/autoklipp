import ClipCore
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Draws one frame of the film with Core Image: places each clip in the frame, moves stills
/// (Ken Burns), applies the style's colour filter and blends neighbours during transitions.
final class FrameRenderer: @unchecked Sendable {
    let timeline: RenderTimeline
    private let stills: StillImageCache
    private let bounds: CGRect
    private let black: CIImage
    private let white: CIImage

    /// Sources whose aspect differs more than this from the frame are fitted over a blurred
    /// copy of themselves instead of being cropped.
    static let fillLimit = 1.4

    init(timeline: RenderTimeline, stills: StillImageCache = StillImageCache()) {
        self.timeline = timeline
        self.stills = stills
        bounds = CGRect(origin: .zero, size: timeline.renderSize)
        black = CIImage(color: .black).cropped(to: bounds)
        white = CIImage(color: .white).cropped(to: bounds)
    }

    /// The finished frame at `time`. `sourceFrame` returns the decoded video frame of a
    /// composition track at that time, if the track has one.
    func image(at time: Double, sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        guard let index = timeline.layerIndex(at: time) else { return black }
        let layers = timeline.layers
        let current = layers[index]
        let incoming = current.transitionIn.duration
        let picture: CIImage
        if index > 0, incoming > 0, time < current.start + incoming / 2 {
            let progress = (time - (current.start - incoming / 2)) / incoming
            picture = blend(
                layerImage(index - 1, time, sourceFrame), layerImage(index, time, sourceFrame),
                current.transitionIn.kind, progress
            )
        } else if index + 1 < layers.count, layers[index + 1].transitionIn.duration > 0,
            time >= layers[index + 1].start - layers[index + 1].transitionIn.duration / 2
        {
            let next = layers[index + 1]
            let progress = (time - (next.start - next.transitionIn.duration / 2)) / next.transitionIn.duration
            picture = blend(
                layerImage(index, time, sourceFrame), layerImage(index + 1, time, sourceFrame),
                next.transitionIn.kind, progress
            )
        } else {
            picture = layerImage(index, time, sourceFrame)
        }
        return picture.composited(over: black).cropped(to: bounds)
    }

    // MARK: Layers

    func layerImage(_ index: Int, _ time: Double, _ sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let layer = timeline.layers[index]
        var placed: CIImage?
        switch layer.content {
        case let .video(trackID, orientation):
            if let buffer = sourceFrame(trackID) {
                placed = place(CIImage(cvPixelBuffer: buffer).oriented(orientation), motion: nil, progress: 0)
            }
        case let .still(url, width, height):
            let zoom = max(layer.kenBurns?.startScale ?? 1, layer.kenBurns?.endScale ?? 1)
            let size = decodeSize(width: width, height: height, zoom: zoom)
            if let still = stills.image(url: url, maxPixelSize: size) {
                let progress = (time - layer.start) / max(0.001, layer.end - layer.start)
                placed = place(still, motion: layer.kenBurns, progress: progress)
            }
        }
        guard let placed else { return black }
        return Self.apply(layer.filter, to: placed, bounds: bounds)
    }

    /// Long side a still must be decoded at so that one image pixel covers at least one frame pixel.
    func decodeSize(width: Int, height: Int, zoom: Double) -> Int {
        let w = Double(max(1, width))
        let h = Double(max(1, height))
        let frameW = Double(bounds.width)
        let frameH = Double(bounds.height)
        let fills = Self.fills(sourceAspect: w / h, frameAspect: frameW / frameH)
        let base = fills ? max(frameW / w, frameH / h) : min(frameW / w, frameH / h)
        return Int((max(w, h) * min(1, base * max(1, zoom))).rounded(.up))
    }

    static func fills(sourceAspect: Double, frameAspect: Double) -> Bool {
        max(sourceAspect, frameAspect) / min(sourceAspect, frameAspect) <= fillLimit
    }

    /// Scales and positions a source in the frame, following a Ken Burns move if given.
    func place(_ source: CIImage, motion: KenBurns?, progress: Double) -> CIImage {
        let image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let w = Double(image.extent.width)
        let h = Double(image.extent.height)
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return black }
        let frameW = Double(bounds.width)
        let frameH = Double(bounds.height)
        let fills = Self.fills(sourceAspect: w / h, frameAspect: frameW / frameH)
        let base = fills ? max(frameW / w, frameH / h) : min(frameW / w, frameH / h)

        let move = motion ?? .none
        let q = min(1.3, max(-0.3, progress))
        let zoom = max(1, move.startScale + (move.endScale - move.startScale) * q)
        let scale = base * zoom
        let centerX = move.startCenter.x + (move.endCenter.x - move.startCenter.x) * q
        let centerY = move.startCenter.y + (move.endCenter.y - move.startCenter.y) * q
        // Focus point in Core Image coordinates (origin bottom left), kept so the picture
        // never slides off the frame.
        let halfW = min(w / 2, frameW / (2 * scale))
        let halfH = min(h / 2, frameH / (2 * scale))
        let focusX = min(max(centerX * w, halfW), w - halfW)
        let focusY = min(max((1 - centerY) * h, halfH), h - halfH)
        let transform = CGAffineTransform(translationX: frameW / 2, y: frameH / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -focusX, y: -focusY)
        let placed = image.transformed(by: transform)
        if fills { return placed.cropped(to: bounds) }

        // Bars are filled with a blurred, slightly darker copy (blurred small for speed).
        let shrink = 8.0
        let fillScale = max(frameW / w, frameH / h) / shrink
        let small = image
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 6)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.1, kCIInputSaturationKey: 0.9])
        let smallW = w * fillScale
        let smallH = h * fillScale
        let backdrop = small
            .transformed(by: CGAffineTransform(translationX: frameW / 2, y: frameH / 2)
                .scaledBy(x: shrink, y: shrink)
                .translatedBy(x: -smallW / 2, y: -smallH / 2))
            .cropped(to: bounds)
        return placed.composited(over: backdrop).cropped(to: bounds)
    }

    // MARK: Look

    static func apply(_ filter: FilterKind, to image: CIImage, bounds: CGRect) -> CIImage {
        switch filter {
        case .none:
            return image
        case .soft:
            return image.applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.88, kCIInputContrastKey: 0.95, kCIInputBrightnessKey: 0.02]
            )
        case .vivid:
            return image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2, kCIInputContrastKey: 1.08])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
        case .vintage:
            return image
                .applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.35])
                .applyingFilter(
                    "CIColorControls",
                    parameters: [kCIInputSaturationKey: 0.8, kCIInputContrastKey: 0.9, kCIInputBrightnessKey: 0.03]
                )
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.9, kCIInputRadiusKey: 1.6])
                .cropped(to: bounds)
        case .warm:
            return image
                .applyingFilter(
                    "CITemperatureAndTint",
                    parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5400, y: 0)]
                )
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.08])
        case .cinematic:
            return image
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.82, kCIInputContrastKey: 1.12])
                .applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 0.6, kCIInputRadiusKey: 2.0])
                .cropped(to: bounds)
        }
    }

    // MARK: Transitions

    func blend(_ from: CIImage, _ to: CIImage, _ kind: TransitionKind, _ progress: Double) -> CIImage {
        let p = min(1, max(0, progress))
        switch kind {
        case .cut:
            return p < 0.5 ? from : to
        case .crossfade:
            return dissolve(from, to, Self.ease(p))
        case .dipToBlack:
            return p < 0.5 ? dissolve(from, black, Self.ease(p * 2)) : dissolve(black, to, Self.ease(p * 2 - 1))
        case .dipToWhite:
            return p < 0.5 ? dissolve(from, white, Self.ease(p * 2)) : dissolve(white, to, Self.ease(p * 2 - 1))
        case .flash:
            let base = p < 0.5 ? from : to
            return dissolve(base, white, 0.9 * pow(1 - abs(2 * p - 1), 1.5))
        case .zoomIn:
            let scale = 1 + 0.35 * Self.ease(p)
            let center = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -bounds.midX, y: -bounds.midY)
            return dissolve(from.transformed(by: center).cropped(to: bounds), to, Self.ease(p))
        case .slideLeft:
            let offset = Double(bounds.width) * Self.ease(p)
            let outgoing = from.transformed(by: CGAffineTransform(translationX: -offset, y: 0))
            let incoming = to.transformed(by: CGAffineTransform(translationX: Double(bounds.width) - offset, y: 0))
            return incoming.composited(over: outgoing).cropped(to: bounds)
        }
    }

    func dissolve(_ from: CIImage, _ to: CIImage, _ amount: Double) -> CIImage {
        from.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: amount])
            .cropped(to: bounds)
    }

    static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}
