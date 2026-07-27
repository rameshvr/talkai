import Foundation
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Ollama")

/// Polishes text using a local Ollama instance.
public final class OllamaPolishBackend: PolishBackend {
    private let config: OllamaConfig

    public var supportsVision: Bool { config.isVisionModel }
    public let displayName = "Ollama (Local)"

    public init(config: OllamaConfig) {
        self.config = config
    }

    public var isAvailable: Bool {
        get async {
            guard let url = URL(string: "\(config.baseURL)/api/tags") else { return false }
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
    }

    public func polish(_ rawText: String, instruction: String, context: PolishContext) async throws -> String {
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rawText
        }

        let url = URL(string: "\(config.baseURL)/api/generate")!

        let prompt = polishUserPrompt(rawText: rawText, instruction: instruction, context: context)

        var body: [String: Any] = [
            "model": config.modelName,
            "prompt": prompt,
            "system": polishSystemInstruction(context: context),
            "stream": false,
            "options": ["temperature": 0.2]
        ]

        // Add screenshot for vision models
        if config.isVisionModel, let screenshot = context.screenshot {
            body["images"] = [screenshot.base64EncodedString()]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = PipelineTiming.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                logger.error("Ollama returned \(code)")
                throw PolishError.httpError(code, bodyText)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["response"] as? String
            else {
                logger.error("Failed to parse Ollama response")
                throw PolishError.parseFailure
            }

            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.notice("Ollama polish succeeded")
            return cleaned
        } catch let error as PolishError {
            throw error
        } catch {
            logger.error("Ollama request failed: \(error)")
            throw PolishError.network(error.localizedDescription)
        }
    }
}
