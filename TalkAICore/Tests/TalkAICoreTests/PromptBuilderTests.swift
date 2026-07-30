import Foundation
import Testing
@testable import TalkAICore

struct PromptBuilderTests {
    @Test func userPromptIncludesScreenTextBlock() {
        let ctx = PolishContext(appName: "Xcode", screenText: "func parseKaleido()")
        let prompt = polishUserPrompt(rawText: "call parse collide oh", instruction: "Clean it.", context: ctx)
        #expect(prompt.contains("Text visible on the user's screen"))
        #expect(prompt.contains("func parseKaleido()"))
        #expect(prompt.contains("Dictated text:"))
        #expect(prompt.hasSuffix("Cleaned text:"))
    }

    @Test func userPromptOmitsEmptyContextBlocks() {
        let prompt = polishUserPrompt(rawText: "hello", instruction: "Clean it.", context: PolishContext())
        #expect(!prompt.contains("Text visible"))
        #expect(!prompt.contains("field being typed into"))
    }

    @Test func userPromptIncludesFocusedFieldText() {
        let ctx = PolishContext(focusedFieldText: "Hi team,")
        let prompt = polishUserPrompt(rawText: "hello", instruction: "Clean it.", context: ctx)
        #expect(prompt.contains("Existing text in the field being typed into"))
        #expect(prompt.contains("Hi team,"))
    }

    @Test func screenTextIsTruncated() {
        let long = String(repeating: "x", count: 5_000)
        let prompt = polishUserPrompt(rawText: "hi", instruction: "Clean.", context: PolishContext(screenText: long))
        #expect(prompt.count < 3_000)
    }

    @Test func toneCategoryMatchesKnownApps() {
        #expect(AppToneCategory.category(appName: "Slack", bundleID: nil) == .chat)
        #expect(AppToneCategory.category(appName: "Visual Studio Code", bundleID: nil) == .codeEditor)
        #expect(AppToneCategory.category(appName: "Mail", bundleID: "com.apple.mail") == .email)
        #expect(AppToneCategory.category(appName: "SomeRandomApp", bundleID: nil) == .generic)
    }

    @Test func systemInstructionIncludesToneForChatApp() {
        let ctx = PolishContext(appName: "Slack")
        let sys = polishSystemInstruction(context: ctx)
        #expect(sys.contains("conversational"))
    }

    @Test func systemInstructionMentionsScreenshotOnlyWhenAttached() {
        let withShot = polishSystemInstruction(context: PolishContext(screenshot: Data([1])))
        let without = polishSystemInstruction(context: PolishContext())
        #expect(withShot.contains("screenshot"))
        #expect(!without.contains("screenshot"))
    }
}
