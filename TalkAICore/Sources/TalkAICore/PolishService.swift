import Foundation
import FoundationModels
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Polish")

/// On-device text polishing using Apple's Foundation Models framework.
public final class PolishService: Sendable {
    public static let defaultInstruction = """
        Rewrite the following dictated text with correct grammar, punctuation, and capitalization. \
        Remove filler words like um, uh, like, you know. \
        Keep the original meaning and tone. Output only the cleaned text.
        """

    public init() {}

    /// Check if the on-device language model is available.
    public var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Polish raw transcription text using the on-device LLM.
    /// Falls back to returning raw text if the model is unavailable.
    public func polish(_ rawText: String, instruction: String = PolishService.defaultInstruction) async throws -> String {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rawText
        }

        guard isAvailable else {
            return rawText
        }

        do {
            // Combine instruction and text into a single prompt to prevent
            // the model from treating the input as a question to answer
            let prompt = """
                \(instruction)

                Dictated text:
                \(rawText)

                Cleaned text:
                """

            let session = LanguageModelSession(instructions: "You are a text rewriting tool. You only output rewritten text. You never explain, answer questions, or add commentary.")
            let response = try await session.respond(to: prompt)
            let result = String(response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("Polish succeeded: \(result)")
            return result
        } catch {
            logger.error("Polish failed: \(error)")
            return rawText
        }
    }
}
