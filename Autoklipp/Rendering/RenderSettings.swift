import CoreGraphics
import Foundation

enum AspectFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 9:16
    case portrait
    /// 16:9
    case landscape
    /// 1:1
    case square

    var id: String { rawValue }
}

enum Resolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case hd1080
    case uhd4k

    var id: String { rawValue }

    /// Length of the short side in pixels.
    var shortSide: Int {
        switch self {
        case .hd1080: 1080
        case .uhd4k: 2160
        }
    }
}

struct RenderSettings: Hashable, Sendable {
    var format: AspectFormat
    var resolution: Resolution
    /// Overrides the short side, used for a lighter preview.
    var previewShortSide: Int?

    init(format: AspectFormat, resolution: Resolution = .hd1080, previewShortSide: Int? = nil) {
        self.format = format
        self.resolution = resolution
        self.previewShortSide = previewShortSide
    }

    static func preview(_ format: AspectFormat) -> RenderSettings {
        RenderSettings(format: format, resolution: .hd1080, previewShortSide: 720)
    }

    var renderSize: CGSize {
        let short = previewShortSide ?? resolution.shortSide
        let long = short * 16 / 9
        switch format {
        case .portrait: return CGSize(width: short, height: long)
        case .landscape: return CGSize(width: long, height: short)
        case .square: return CGSize(width: short, height: short)
        }
    }
}
