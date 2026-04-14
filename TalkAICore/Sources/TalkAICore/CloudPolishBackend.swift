import Foundation
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Cloud")

/// Polishes text using a cloud API (Claude or OpenAI).
public final class CloudPolishBackend: PolishBackend {
    private let config: CloudConfig

    public var supportsVision: Bool { true }
    public var displayName: String { config.provider.displayName }

    public init(config: CloudConfig) {
        self.config = config
    }

    public var isAvailable: Bool {
        get async { config.isConfigured }
    }

    public func polish(_ rawText: String, instruction: String, context: PolishContext) async throws -> String {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rawText
        }

        guard config.isConfigured else {
            logger.warning("Cloud API key not configured")
            return rawText
        }

        switch config.provider {
        case .claude:
            return try await polishWithClaude(rawText, instruction: instruction, context: context)
        case .openai:
            return try await polishWithOpenAI(rawText, instruction: instruction, context: context)
        }
    }

    // MARK: - Claude

    private func polishWithClaude(_ rawText: String, instruction: String, context: PolishContext) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        let userPrompt = """
            \(instruction)

            Dictated text:
            \(rawText)

            Cleaned text:
            """

        let systemInstruction = polishSystemInstruction(context: context)

        // Build content array with optional image
        var content: [[String: Any]] = []

        if let screenshot = context.screenshot {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": screenshot.base64EncodedString()
                ] as [String: Any]
            ])
        }

        content.append([
            "type": "text",
            "text": userPrompt
        ])

        let body: [String: Any] = [
            "model": config.modelName,
            "max_tokens": 4096,
            "system": systemInstruction,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await executeRequest(request, rawText: rawText, parser: parseClaudeResponse)
    }

    private func parseClaudeResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String
        else { return nil }
        return text
    }

    // MARK: - OpenAI

    private func polishWithOpenAI(_ rawText: String, instruction: String, context: PolishContext) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        let userPrompt = """
            \(instruction)

            Dictated text:
            \(rawText)

            Cleaned text:
            """

        // Build content array with optional image
        var content: [[String: Any]] = []

        if let screenshot = context.screenshot {
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/png;base64,\(screenshot.base64EncodedString())"
                ]
            ])
        }

        content.append([
            "type": "text",
            "text": userPrompt
        ])

        let systemInstruction = polishSystemInstruction(context: context)

        let body: [String: Any] = [
            "model": config.modelName,
            "max_tokens": 4096,
            "messages": [
                [
                    "role": "system",
                    "content": systemInstruction
                ],
                ["role": "user", "content": content]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await executeRequest(request, rawText: rawText, parser: parseOpenAIResponse)
    }

    private func parseOpenAIResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String
        else { return nil }
        return text
    }

    // MARK: - Common

    private func executeRequest(
        _ request: URLRequest,
        rawText: String,
        parser: (Data) -> String?
    ) async throws -> String {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                logger.error("Invalid response type")
                return rawText
            }

            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                logger.error("Cloud API returned \(httpResponse.statusCode): \(body)")
                return rawText
            }

            guard let result = parser(data) else {
                logger.error("Failed to parse cloud API response")
                return rawText
            }

            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.notice("Cloud polish succeeded: \(cleaned)")
            return cleaned
        } catch {
            logger.error("Cloud request failed: \(error)")
            return rawText
        }
    }
}
