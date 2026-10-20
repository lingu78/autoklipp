import ClipCore
import Foundation
import FoundationModels

/// The model's answer for one batch of clips (guided generation).
@Generable(description: "A plan for a short film made from the user's clips")
struct DirectorResponse {
    @Guide(description: "Ids of the clips that fit the wish (such as c3), in the order they should appear in the film")
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

    /// Tokens kept free for the answer.
    static let answerReserve = 1_200

    /// Asks the model for a plan, batch by batch so long material fits the context window.
    static func plan(instruction: String, media: [MediaItem], analyses: [String: MediaAnalysis]) async throws -> DirectorPlan? {
        let model = SystemLanguageModel.default
        let descriptions = DirectorBriefing.describe(media, analyses: analyses)
        guard !descriptions.isEmpty else { return nil }

        let fixed = instructionText + "\nWish: " + instruction + "\nClips:\n"
        let budget = max(400, model.contextSize - answerReserve - (try await tokens(fixed, model: model)))
        // Count each line with the framework where it can count, else estimate.
        var costs: [String: Int] = [:]
        for description in descriptions {
            costs[description.line] = try await tokens(description.line, model: model)
        }
        let batches = DirectorBriefing.batches(descriptions, budget: budget) { costs[$0] ?? DirectorBriefing.estimatedTokens($0) }

        var answers: [DirectorAnswer] = []
        for batch in batches {
            try Task.checkCancellation()
            let session = LanguageModelSession(model: model) {
                instructionText
            }
            let promptText = "Wish: \(instruction)\nClips:\n" + batch.map(\.line).joined(separator: "\n")
            let response = try await session.respond(to: Prompt { promptText }, generating: DirectorResponse.self)
            let content = response.content
            answers.append(
                DirectorAnswer(
                    clipIDs: content.clipIDs,
                    chapters: content.chapters.map { DirectorAnswer.Chapter(title: $0.title, clipIDs: $0.clipIDs) },
                    style: content.style,
                    title: content.title
                )
            )
        }
        return DirectorBriefing.plan(from: answers, descriptions: descriptions)
    }

    static func tokens(_ text: String, model: SystemLanguageModel) async throws -> Int {
        if #available(iOS 26.4, *) {
            return try await model.tokenCount(for: Instructions { text })
        }
        return DirectorBriefing.estimatedTokens(text)
    }
}
