import Foundation
import FoundationModels
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "ApplePolish")

/// On-device text polishing using Apple's Foundation Models framework.
public final class ApplePolishBackend: PolishBackend {
    public let supportsVision = false
    public let displayName = "Apple On-Device"

    public init() {}

    public var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func polish(_ rawText: String, instruction: String, context: PolishContext) async throws -> String {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rawText
        }

        guard isAvailable else {
            return rawText
        }

        do {
            let prompt = """
                \(instruction)

                Dictated text:
                \(rawText)

                Cleaned text:
                """

            let session = LanguageModelSession(
                instructions: polishSystemInstruction(context: context)
            )
            let response = try await session.respond(to: prompt)
            let result = String(response.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logger.notice("Polish succeeded: \(result)")
            return result
        } catch {
            logger.error("Polish failed: \(error)")
            return rawText
        }
    }
}
