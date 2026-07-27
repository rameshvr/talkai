import Foundation

/// Extracts likely proper nouns / technical identifiers from OCR'd screen text.
/// Output biases Whisper recognition (initial prompt) and the polish prompt.
public enum HotwordExtractor {
    private static let stopwords: Set<String> = [
        "the", "this", "that", "these", "those", "and", "for", "you", "with",
        "are", "was", "were", "not", "but", "have", "has", "had", "from",
        "they", "will", "what", "when", "where", "which", "your", "can",
        "all", "use", "new", "one", "two", "how", "its", "our", "out",
        "get", "see", "now", "also", "here", "there", "then", "than",
        "file", "edit", "view", "window", "help", "close", "open", "save",
        "settings", "search", "menu", "button", "click", "page", "home"
    ]

    public static func extract(from screenText: String, maxCount: Int = 40) -> [String] {
        var counts: [String: (variants: Set<String>, count: Int)] = [:]

        let tokens = screenText.split { ch in
            !(ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-")
        }

        for raw in tokens {
            let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
            guard token.count >= 3, token.count <= 40 else { continue }
            guard token.contains(where: \.isLetter) else { continue }

            let lower = token.lowercased()
            guard !stopwords.contains(lower) else { continue }

            let hasInnerUppercase = token.dropFirst().contains(where: \.isUppercase)
            let hasDigit = token.contains(where: \.isNumber)
            let hasSeparator = token.contains("_") || token.contains(".") || token.contains("-")
            let isCapitalized = token.first?.isUppercase == true
            guard hasInnerUppercase || hasDigit || hasSeparator || isCapitalized else { continue }

            var entry = counts[lower] ?? (variants: [], count: 0)
            entry.variants.insert(token)
            entry.count += 1
            counts[lower] = entry
        }

        var results: [String] = []
        let sorted = counts.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.variants.sorted().first ?? "" < $1.variants.sorted().first ?? ""
            }

        for entry in sorted {
            for variant in entry.variants.sorted() {
                results.append(variant)
                if results.count >= maxCount { break }
            }
            if results.count >= maxCount { break }
        }

        return Array(results.prefix(maxCount))
    }

    /// Formats hotwords as a short glossary line for prompts. Nil when empty.
    public static func prompt(from hotwords: [String]) -> String? {
        guard !hotwords.isEmpty else { return nil }
        return "Glossary: " + hotwords.joined(separator: ", ") + "."
    }
}
