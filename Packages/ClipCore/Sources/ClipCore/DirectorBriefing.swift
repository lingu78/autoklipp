import Foundation

/// One clip as the AI director sees it: a short id and a line of text.
public struct ClipDescription: Sendable, Hashable {
    /// Short id used in prompts ("c12"), cheaper in tokens than a media id.
    public var shortID: String
    public var mediaID: String
    public var line: String

    public init(shortID: String, mediaID: String, line: String) {
        self.shortID = shortID
        self.mediaID = mediaID
        self.line = line
    }
}

/// What the language model answered for one batch, before validation.
public struct DirectorAnswer: Sendable, Hashable {
    public struct Chapter: Sendable, Hashable {
        public var title: String
        public var clipIDs: [String]

        public init(title: String, clipIDs: [String]) {
            self.title = title
            self.clipIDs = clipIDs
        }
    }

    public var clipIDs: [String]
    public var chapters: [Chapter]
    public var style: String?
    public var title: String?
    /// Short ids of the clips this batch showed the model. Other ids are dropped, so an id the
    /// model makes up cannot pull in a clip from another batch. Nil accepts every described clip.
    public var offeredIDs: [String]?

    public init(
        clipIDs: [String], chapters: [Chapter] = [], style: String? = nil, title: String? = nil, offeredIDs: [String]? = nil
    ) {
        self.clipIDs = clipIDs
        self.chapters = chapters
        self.style = style
        self.title = title
        self.offeredIDs = offeredIDs
    }
}

/// Everything around the AI director that does not need the model itself: describing the
/// material as compact text (never pixels), splitting it into batches that fit the context
/// window, and turning the answers into a plan the planner can follow. The model decides what
/// and in which order; timing always stays with the planner.
public enum DirectorBriefing {
    /// Labels per clip in the description.
    public static let labelsPerClip = 6

    /// One line per media item, in chronological order:
    /// `c3 | 2026-06-21 14:05 | video 12 s | 59.33N 18.07E | quality 0.72 | faces 2 | child, beach`.
    public static func describe(_ media: [MediaItem], analyses: [String: MediaAnalysis], timeZone: TimeZone = .current)
        -> [ClipDescription]
    {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return media.chronological().enumerated().map { index, item in
            let analysis = analyses[item.id]
            var parts = ["c\(index + 1)"]
            parts.append(item.creationDate.map { formatter.string(from: $0) } ?? "unknown time")
            switch item.kind {
            case .video: parts.append("video \(Int(item.duration.rounded())) s")
            case .photo: parts.append("photo")
            case .livePhoto: parts.append("live photo")
            }
            if let location = item.location {
                parts.append(coordinate(location.latitude, positive: "N", negative: "S") + " "
                    + coordinate(location.longitude, positive: "E", negative: "W"))
            }
            if let analysis {
                parts.append(String(format: "quality %.2f", quality(analysis)))
                let faces = analysis.still?.faceCount ?? analysis.segments.map(\.metrics.faceCount).max() ?? 0
                if faces > 0 { parts.append("faces \(faces)") }
                let labels = analysis.labels.prefix(labelsPerClip)
                if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
            }
            return ClipDescription(shortID: "c\(index + 1)", mediaID: item.id, line: parts.joined(separator: " | "))
        }
    }

    /// Splits descriptions into consecutive batches whose lines together cost at most `budget`.
    /// A single line above the budget gets a batch of its own.
    public static func batches(_ items: [ClipDescription], budget: Int, cost: (String) -> Int) -> [[ClipDescription]] {
        var result: [[ClipDescription]] = []
        var current: [ClipDescription] = []
        var used = 0
        for item in items {
            let price = cost(item.line) + 1
            if !current.isEmpty, used + price > budget {
                result.append(current)
                current = []
                used = 0
            }
            current.append(item)
            used += price
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A rough token estimate for when the framework cannot count (about four characters each).
    public static func estimatedTokens(_ text: String) -> Int {
        max(1, (text.utf8.count + 3) / 4)
    }

    /// Validates the answers (unknown ids and ids the batch did not offer dropped, duplicates
    /// removed) and merges batches in their order. Returns nil when the model chose nothing usable.
    public static func plan(from answers: [DirectorAnswer], descriptions: [ClipDescription]) -> DirectorPlan? {
        let byShortID = Dictionary(descriptions.map { ($0.shortID.lowercased(), $0.mediaID) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ ids: [String], offered: Set<String>?, into seen: inout Set<String>) -> [String] {
            ids.compactMap { raw in
                let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard offered?.contains(key) ?? true, let mediaID = byShortID[key], seen.insert(mediaID).inserted else { return nil }
                return mediaID
            }
        }

        var seen = Set<String>()
        var chapters: [DirectorChapter] = []
        var ordered: [String] = []
        for answer in answers {
            let offered = answer.offeredIDs.map { Set($0.map { $0.lowercased() }) }
            // Chapters give the order when present; clips outside any chapter follow.
            for chapter in answer.chapters {
                let ids = resolve(chapter.clipIDs, offered: offered, into: &seen)
                guard !ids.isEmpty else { continue }
                chapters.append(DirectorChapter(title: chapter.title.trimmingCharacters(in: .whitespacesAndNewlines), mediaIDs: ids))
                ordered += ids
            }
            ordered += resolve(answer.clipIDs, offered: offered, into: &seen)
        }
        guard !ordered.isEmpty else { return nil }

        var votes: [StyleID: Int] = [:]
        var firstVote: [StyleID: Int] = [:]
        for (index, answer) in answers.enumerated() {
            guard let raw = answer.style?.lowercased(), let style = StyleID(rawValue: raw) else { continue }
            votes[style, default: 0] += 1
            if firstVote[style] == nil { firstVote[style] = index }
        }
        let style = votes.max { lhs, rhs in
            lhs.value == rhs.value ? (firstVote[lhs.key] ?? 0) > (firstVote[rhs.key] ?? 0) : lhs.value < rhs.value
        }?.key
        let title = answers.lazy.compactMap { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return DirectorPlan(mediaIDs: ordered, chapters: chapters, suggestedStyle: style, title: title.map { String($0.prefix(60)) })
    }

    static func quality(_ analysis: MediaAnalysis) -> Double {
        if let still = analysis.still { return Scorer.stillScore(still) }
        let scores = analysis.segments.map { Scorer.score($0.metrics) }.sorted(by: >)
        let top = scores.prefix(max(1, scores.count / 2))
        return top.isEmpty ? 0.5 : top.reduce(0, +) / Double(top.count)
    }

    static func coordinate(_ value: Double, positive: String, negative: String) -> String {
        String(format: "%.2f%@", abs(value), value >= 0 ? positive : negative)
    }
}
