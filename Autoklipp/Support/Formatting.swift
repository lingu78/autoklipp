import Foundation

enum Formatting {
    /// "1 min, 15 s" style, localised; whole seconds.
    static func duration(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return Duration.seconds(whole).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    /// "0:42" style for thumbnails.
    static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
