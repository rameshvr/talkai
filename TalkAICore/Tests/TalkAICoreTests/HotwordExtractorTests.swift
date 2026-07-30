import Testing
@testable import TalkAICore

struct HotwordExtractorTests {
    @Test func keepsCamelCaseIdentifiers() {
        let words = HotwordExtractor.extract(from: "let polishService = PolishService()")
        #expect(words.contains("polishService"))
        #expect(words.contains("PolishService"))
    }

    @Test func keepsCapitalizedProperNouns() {
        let words = HotwordExtractor.extract(from: "email Priyatham about the Kaleido launch")
        #expect(words.contains("Priyatham"))
        #expect(words.contains("Kaleido"))
    }

    @Test func dropsCommonWordsAndStopwords() {
        let words = HotwordExtractor.extract(from: "the quick brown fox jumps over this lazy dog")
        #expect(words.isEmpty)
    }

    @Test func ranksByFrequency() {
        let words = HotwordExtractor.extract(from: "Kaleido Kaleido Kaleido Zephyr")
        #expect(words.first == "Kaleido")
    }

    @Test func capsAtMaxCount() {
        let text = (1...100).map { "Term\($0)" }.joined(separator: " ")
        let words = HotwordExtractor.extract(from: text, maxCount: 10)
        #expect(words.count == 10)
    }

    @Test func dropsPureNumbersAndShortTokens() {
        let words = HotwordExtractor.extract(from: "42 3.14 ab OK")
        #expect(words.isEmpty)
    }

    @Test func promptFormatsGlossary() {
        #expect(HotwordExtractor.prompt(from: ["Kaleido", "Zephyr"]) == "Glossary: Kaleido, Zephyr.")
        #expect(HotwordExtractor.prompt(from: []) == nil)
    }
}
