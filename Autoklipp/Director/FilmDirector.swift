import ClipCore
import Foundation
import FoundationModels

/// The model's answer for one batch of clips (guided generation).
@Generable(description: "A plan for a short film made from the user's clips")
struct DirectorResponse {
    @Guide(description: "Ids from the clip list that fit the wish, in the order they should appear in the film")
    var clipIDs: [String]

    @Guide(description: "Chapters of the film in order, each with a short title and the ids of its clips", .maximumCount(6))
    var chapters: [DirectorChapterResponse]

    @Guide(description: "The visual style that suits the wish best", .anyOf(["calm", "energetic", "nostalgic", "travel", "cinematic"]))
    var style: String

    @Guide(description: "A short, warm title for the film in the language of the wish, at most five words")
    var title: String
}

@Generable(description: "A chapter of the film")
struct DirectorChapterResponse {
    @Guide(description: "Chapter title, at most four words")
    var title: String

    @Guide(description: "Ids of the clips in this chapter, in order")
    var clipIDs: [String]
}

/// The optional AI director (F16): Apple's on-device language model decides which clips fit the
/// user's wish and in what order. It only ever sees one line of text per clip, never pictures,
/// and never decides timing. Without Apple Intelligence the app works as before.
enum FilmDirector {
    /// Whether the free-text field should be shown: the model is ready and speaks the user's language.
    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.isAvailable && model.supportsLocale()
    }

    static let instructionText = """
        You are the director of a short home video. The user describes the film they want. \
        You get one line per clip: an id, when it was recorded, photo or video, place, a quality \
        score from 0 to 1, how many faces were found and what the picture shows. Choose the clips \
        that fit the user's wish, prefer higher quality, keep enough clips for a lively film, and \
        put them in a good order, usually chronological. Group them into a few chapters. Only use \
        ids from the list. Never invent clips.
        """

    /// Tokens kept free for the answer format the framework adds to the prompt and for the
    /// answer's fixed parts (style, title, chapter titles).
    static let answerReserve = 1_000
    /// Tokens each clip of a batch may need in the answer: its id can appear twice, in the list
    /// and in a chapter.
    static let answerTokensPerClip = 10

    /// Asks the model for a plan, batch by batch so long material fits the context window.
    static func plan(instruction: String, media: [MediaItem], analyses: [String: MediaAnalysis]) async throws -> DirectorPlan? {
        let model = SystemLanguageModel.default
        let descriptions = DirectorBriefing.describe(media, analyses: analyses)
        guard !descriptions.isEmpty else { return nil }

        let fixed = instructionText + "\nWish: " + instruction + "\nClips:\n"
        let budget = model.contextSize - answerReserve - (try await tokens(fixed, model: model))
        // A description so long that only a few clips would fit beside it cannot be directed.
        guard budget >= 400 else { return nil }
        // Count each line with the framework where it can count, else estimate, plus its room in
        // the answer.
        var costs: [String: Int] = [:]
        for description in descriptions {
            costs[description.line] = try await tokens(description.line, model: model) + answerTokensPerClip
        }
        var pending = DirectorBriefing.batches(descriptions, budget: budget) {
            costs[$0] ?? estimatedTokens($0) + answerTokensPerClip
        }

        // A batch that fails because of its own clips loses only those; the description fails
        // when all batches do, or at once on an error that is not about the batch.
        var answers: [DirectorAnswer] = []
        var failure: (any Error)?
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = pending.removeFirst()
            do {
                answers.append(try await answer(instruction: instruction, batch: batch, model: model))
            } catch let error as LanguageModelSession.GenerationError where concernsOnlyItsBatch(error) {
                if case .exceededContextWindowSize = error, batch.count > 1 {
                    // The batch was counted too small: ask again with each half.
                    let half = batch.count / 2
                    pending.insert(contentsOf: [Array(batch[..<half]), Array(batch[half...])], at: 0)
                } else {
                    failure = error
                }
            }
        }
        if answers.isEmpty, let failure { throw failure }
        return DirectorBriefing.plan(from: answers, descriptions: descriptions)
    }

    /// Whether a failed batch only loses its own clips: its lines did not fit, tripped the
    /// guardrails or got an unreadable answer. Anything else, such as a rate limit (the app went to
    /// the background) or missing model assets, would hit the other batches too, so the plan fails
    /// as a whole rather than quietly leaving part of the material out.
    private static func concernsOnlyItsBatch(_ error: LanguageModelSession.GenerationError) -> Bool {
        switch error {
        case .exceededContextWindowSize, .guardrailViolation, .decodingFailure:
            return true
        default:
            return false
        }
    }

    /// The model's answer for one batch of clips.
    private static func answer(instruction: String, batch: [ClipDescription], model: SystemLanguageModel) async throws
        -> DirectorAnswer
    {
        let session = LanguageModelSession(model: model) {
            instructionText
        }
        let promptText = "Wish: \(instruction)\nClips:\n" + batch.map(\.line).joined(separator: "\n")
        let response = try await session.respond(to: Prompt { promptText }, generating: DirectorResponse.self)
        let content = response.content
        return DirectorAnswer(
            clipIDs: content.clipIDs,
            chapters: content.chapters.map { DirectorAnswer.Chapter(title: $0.title, clipIDs: $0.clipIDs) },
            style: content.style,
            title: content.title,
            offeredIDs: batch.map(\.shortID)
        )
    }

    static func tokens(_ text: String, model: SystemLanguageModel) async throws -> Int {
        if #available(iOS 26.4, *) {
            return try await model.tokenCount(for: Instructions { text })
        }
        return estimatedTokens(text)
    }

    /// A cautious estimate for when the framework cannot count: the clip lines are mostly dates,
    /// coordinates and scores, which split into short tokens, so one and a half characters each.
    static func estimatedTokens(_ text: String) -> Int {
        max(1, (text.utf8.count * 2 + 2) / 3)
    }
}
