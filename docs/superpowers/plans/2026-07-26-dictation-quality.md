# TalkAI Dictation Quality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Vibing-level dictation quality, fully local: Whisper transcription with OCR-derived hotword biasing, a rich context bundle (screen text, focused-field text, app name) for every polish backend, app-aware tone, and visible (not silent) failure handling.

**Architecture:** TalkAI is a pure SPM package (NO Xcode project) — root `Package.swift` defines the `TalkAICore` library + `TalkAI` executable; `./build-app.sh` assembles the .app bundle. We add WhisperKit (SPM, CoreML-accelerated Whisper with `promptTokens` biasing) as the STT default behind a new `TranscriptionBackend` protocol, extract screen text via the Vision framework (works with Apple Intelligence OFF), and thread the context through the existing `PolishContext` into all backends.

**Tech Stack:** Swift 6.2, macOS 26, SwiftUI, WhisperKit (new dependency), Vision framework, ScreenCaptureKit (existing), Ollama HTTP API (existing).

## Global Constraints

- Build with `rtk swift build 2>&1 | tail -20`; test with `rtk swift test 2>&1 | tail -30`. All shell commands are prefixed with `rtk`.
- Do NOT run `./build-app.sh` after every task — macOS revokes Accessibility/Screen Recording permission when the app binary changes. Compile-check with `swift build`; assemble the bundle only in the final task.
- Swift 6 strict concurrency is ON. New classes crossing actor boundaries follow the existing pattern: `final class X: @unchecked Sendable` (see `SpeechService`).
- The nested `TalkAICore/Package.swift` is vestigial — the ROOT `/Package.swift` is the real manifest. All target changes go in the root file.
- Verbatim string constants below (copy exactly):
  - Default Ollama model: `qwen2.5:3b`
  - Default Whisper model: `base.en`
  - UserDefaults keys: `sttEngine` (values `"whisper"` / `"apple"`), `whisperModel`, `polishEnabled`, plus existing `useScreenshotContext`, `ollamaModel`, etc.
- WhisperKit API names (`DecodingOptions`, `promptTokens`, `transcribe(audioArray:decodeOptions:)`) are from WhisperKit ≥0.9. If a signature differs at build time, check the pinned version's source in `.build/checkouts/WhisperKit/Sources/WhisperKit/Core/` — do not guess.

---

### Task 1: Test target + HotwordExtractor

**Files:**
- Modify: `Package.swift` (root)
- Create: `TalkAICore/Sources/TalkAICore/HotwordExtractor.swift`
- Test: `TalkAICore/Tests/TalkAICoreTests/HotwordExtractorTests.swift`

**Interfaces:**
- Produces: `HotwordExtractor.extract(from: String, maxCount: Int = 40) -> [String]` and `HotwordExtractor.prompt(from: [String]) -> String?` — used by Task 6 (Whisper initial prompt) and Task 8 (coordinator).

- [ ] **Step 1: Add test target to root Package.swift**

In `/Package.swift`, add to the `targets:` array (after the executable target):

```swift
        .testTarget(
            name: "TalkAICoreTests",
            dependencies: ["TalkAICore"],
            path: "TalkAICore/Tests/TalkAICoreTests"
        )
```

- [ ] **Step 2: Write the failing test**

Create `TalkAICore/Tests/TalkAICoreTests/HotwordExtractorTests.swift`:

```swift
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `rtk swift test --filter HotwordExtractorTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'HotwordExtractor'`

- [ ] **Step 4: Write the implementation**

Create `TalkAICore/Sources/TalkAICore/HotwordExtractor.swift`:

```swift
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
        var counts: [String: (display: String, count: Int)] = [:]

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

            var entry = counts[lower] ?? (display: token, count: 0)
            entry.count += 1
            counts[lower] = entry
        }

        return counts.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.display < $1.display
            }
            .prefix(maxCount)
            .map(\.display)
    }

    /// Formats hotwords as a short glossary line for prompts. Nil when empty.
    public static func prompt(from hotwords: [String]) -> String? {
        guard !hotwords.isEmpty else { return nil }
        return "Glossary: " + hotwords.joined(separator: ", ") + "."
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `rtk swift test --filter HotwordExtractorTests 2>&1 | tail -20`
Expected: PASS (7 tests)

- [ ] **Step 6: Commit**

```bash
rtk git add Package.swift TalkAICore/Sources/TalkAICore/HotwordExtractor.swift TalkAICore/Tests/TalkAICoreTests/HotwordExtractorTests.swift
rtk git commit -m "feat: add HotwordExtractor and TalkAICore test target"
```

---

### Task 2: Context bundle + app-aware prompts

**Files:**
- Modify: `TalkAICore/Sources/TalkAICore/PolishBackend.swift`, `OllamaPolishBackend.swift`, `CloudPolishBackend.swift`, `ApplePolishBackend.swift`
- Create: `TalkAICore/Sources/TalkAICore/AppToneCategory.swift`
- Test: `TalkAICore/Tests/TalkAICoreTests/PromptBuilderTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (used by Tasks 3, 8):
  - `PolishContext` gains `screenText: String?`, `focusedFieldText: String?`, `appBundleID: String?` (all default nil; existing 3 fields unchanged).
  - `polishUserPrompt(rawText: String, instruction: String, context: PolishContext) -> String` — replaces the inline prompt template in all three backends.
  - `AppToneCategory.category(appName: String?, bundleID: String?) -> AppToneCategory` and `.toneInstruction: String?`.

- [ ] **Step 1: Write the failing test**

Create `TalkAICore/Tests/TalkAICoreTests/PromptBuilderTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk swift test --filter PromptBuilderTests 2>&1 | tail -20`
Expected: FAIL — no member `screenText`, cannot find `polishUserPrompt`, `AppToneCategory`

- [ ] **Step 3: Create AppToneCategory.swift**

```swift
import Foundation

/// Coarse category of the app being dictated into, driving output tone.
public enum AppToneCategory: Sendable, Equatable {
    case chat, codeEditor, terminal, email, document, generic

    private static let chatApps = ["slack", "discord", "messages", "telegram", "whatsapp", "signal"]
    private static let codeApps = ["xcode", "visual studio code", "code", "cursor", "zed", "intellij", "pycharm", "sublime"]
    private static let terminalApps = ["terminal", "iterm", "warp", "ghostty", "alacritty", "kitty"]
    private static let emailApps = ["mail", "outlook", "spark", "mimestream"]
    private static let documentApps = ["pages", "word", "notes", "notion", "obsidian", "textedit", "bear", "craft"]

    public static func category(appName: String?, bundleID: String?) -> AppToneCategory {
        let name = (appName ?? "").lowercased()
        let bundle = (bundleID ?? "").lowercased()
        func matches(_ list: [String]) -> Bool {
            list.contains { name.contains($0) || bundle.contains($0) }
        }
        if matches(chatApps) { return .chat }
        if matches(codeApps) { return .codeEditor }
        if matches(terminalApps) { return .terminal }
        if matches(emailApps) { return .email }
        if matches(documentApps) { return .document }
        return .generic
    }

    /// Tone rule appended to the system instruction. Nil for generic.
    public var toneInstruction: String? {
        switch self {
        case .chat:
            return "The user is writing a chat message: keep it conversational and natural, preserve emotion and casual phrasing."
        case .codeEditor:
            return "The user is writing in a code editor: be literal, preserve technical terms, identifiers, and symbols exactly; do not paraphrase code."
        case .terminal:
            return "The user is typing into a terminal: output the command or text verbatim with no embellishment."
        case .email:
            return "The user is writing an email: use clear, professional prose with proper sentences."
        case .document:
            return "The user is writing a document: use clear, well-structured prose."
        case .generic:
            return nil
        }
    }
}
```

- [ ] **Step 4: Extend PolishContext and prompt builders in PolishBackend.swift**

Replace the `PolishContext` struct (lines 3–14) with:

```swift
/// Context about the user's active application when dictation started.
public struct PolishContext: Sendable {
    public let appName: String?
    public let windowTitle: String?
    public let screenshot: Data?
    public let screenText: String?
    public let focusedFieldText: String?
    public let appBundleID: String?

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        screenshot: Data? = nil,
        screenText: String? = nil,
        focusedFieldText: String? = nil,
        appBundleID: String? = nil
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenshot = screenshot
        self.screenText = screenText
        self.focusedFieldText = focusedFieldText
        self.appBundleID = appBundleID
    }
}
```

In `polishSystemInstruction(context:)`, after the existing `The user is currently typing in:` block and before the screenshot sentence, insert the tone rule:

```swift
    if let tone = AppToneCategory.category(appName: context.appName, bundleID: context.appBundleID).toneInstruction {
        instruction += " " + tone
    }
```

Then ADD the shared user-prompt builder to the same file (below `polishSystemInstruction`):

```swift
private let maxScreenTextChars = 1_500
private let maxFieldTextChars = 600

/// Builds the user prompt shared by all polish backends: instruction,
/// optional context blocks, then the dictated text.
public func polishUserPrompt(rawText: String, instruction: String, context: PolishContext) -> String {
    var sections: [String] = [instruction]

    if let screen = context.screenText?.trimmingCharacters(in: .whitespacesAndNewlines), !screen.isEmpty {
        let clipped = String(screen.prefix(maxScreenTextChars))
        sections.append("Text visible on the user's screen (reference for spelling and terminology — never copy it into the output):\n\(clipped)")
    }

    if let field = context.focusedFieldText?.trimmingCharacters(in: .whitespacesAndNewlines), !field.isEmpty {
        let clipped = String(field.suffix(maxFieldTextChars))
        sections.append("Existing text in the field being typed into (the dictation continues it):\n\(clipped)")
    }

    sections.append("Dictated text:\n\(rawText)")
    sections.append("Cleaned text:")
    return sections.joined(separator: "\n\n")
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `rtk swift test --filter PromptBuilderTests 2>&1 | tail -20`
Expected: PASS (7 tests). Also run `rtk swift build 2>&1 | tail -5` — whole package still compiles.

- [ ] **Step 6: Switch all three backends to the shared builder**

In `OllamaPolishBackend.swift` replace the `let prompt = """..."""` literal (lines 36–43) with:

```swift
        let prompt = polishUserPrompt(rawText: rawText, instruction: instruction, context: context)
```

In `CloudPolishBackend.swift` do the same for BOTH `let userPrompt = """..."""` literals (Claude lines 44–51, OpenAI lines 108–115):

```swift
        let userPrompt = polishUserPrompt(rawText: rawText, instruction: instruction, context: context)
```

In `ApplePolishBackend.swift` find the equivalent prompt literal and replace identically (variable name may differ — match whatever `respond(to:)` consumes).

- [ ] **Step 7: Build and commit**

Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add TalkAICore/Sources/TalkAICore/ TalkAICore/Tests/
rtk git commit -m "feat: context bundle (screen text, field text, bundle ID) and app-aware tone in polish prompts"
```

---

### Task 3: Visible failures — backends throw, result carries polishError

**Files:**
- Modify: `TalkAICore/Sources/TalkAICore/Models.swift`, `OllamaPolishBackend.swift`, `CloudPolishBackend.swift`, `ApplePolishBackend.swift`, `TranscriptionPipeline.swift`
- Test: `TalkAICore/Tests/TalkAICoreTests/PolishErrorTests.swift`

**Interfaces:**
- Produces (used by Tasks 4, 8, 9):
  - `PolishError: Error, LocalizedError` enum with cases `.backendUnavailable(String)`, `.httpError(Int, String)`, `.parseFailure`, `.network(String)`.
  - `TranscriptionResult.polishError: String?` (new stored property, default nil, Codable-compatible with old history JSON).
  - `PipelineTiming.requestTimeout: TimeInterval = 60`, `PipelineTiming.resultWaitTimeout: TimeInterval = 75`.
  - `TranscriptionPipeline.polishEnabled: Bool` (default true) — polish skipped when false.

- [ ] **Step 1: Write the failing test**

Create `TalkAICore/Tests/TalkAICoreTests/PolishErrorTests.swift`:

```swift
import Foundation
import Testing
@testable import TalkAICore

struct PolishErrorTests {
    @Test func oldHistoryJSONStillDecodes() throws {
        let old = """
        {"id":"6BB13D2F-0000-0000-0000-000000000000","rawText":"a","polishedText":"b","date":770000000}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(TranscriptionResult.self, from: old)
        #expect(result.polishError == nil)
    }

    @Test func resultCarriesPolishError() {
        let r = TranscriptionResult(rawText: "a", polishedText: "a", polishError: "Ollama unreachable")
        #expect(r.polishError == "Ollama unreachable")
    }

    @Test func waitTimeoutExceedsRequestTimeout() {
        #expect(PipelineTiming.resultWaitTimeout > PipelineTiming.requestTimeout)
    }

    @Test func polishErrorDescribesItself() {
        let e = PolishError.httpError(500, "boom")
        #expect(e.localizedDescription.contains("500"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk swift test --filter PolishErrorTests 2>&1 | tail -20`
Expected: FAIL — no `polishError`, no `PipelineTiming`, no `PolishError`

- [ ] **Step 3: Extend Models.swift**

Add to `Models.swift`:

```swift
// MARK: - Errors & Timing

/// Errors thrown by polish backends. Callers surface these — never swallow.
public enum PolishError: Error, LocalizedError, Sendable {
    case backendUnavailable(String)
    case httpError(Int, String)
    case parseFailure
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .backendUnavailable(let name): "\(name) is not available."
        case .httpError(let code, let body): "Backend returned HTTP \(code): \(String(body.prefix(200)))"
        case .parseFailure: "Could not parse the backend response."
        case .network(let msg): "Network error: \(msg)"
        }
    }
}

/// Single source of truth for pipeline timing. The result wait MUST exceed
/// the per-request timeout so late polish results are never dropped.
public enum PipelineTiming {
    public static let requestTimeout: TimeInterval = 60
    public static let resultWaitTimeout: TimeInterval = 75
}
```

In `TranscriptionResult`, add the stored property and init parameter:

```swift
public struct TranscriptionResult: Sendable, Codable, Identifiable {
    public let id: UUID
    public let rawText: String
    public let polishedText: String
    public let date: Date
    /// Non-nil when polish failed and polishedText fell back to rawText.
    public let polishError: String?

    public init(rawText: String, polishedText: String, polishError: String? = nil) {
        self.id = UUID()
        self.rawText = rawText
        self.polishedText = polishedText
        self.date = Date()
        self.polishError = polishError
    }
}
```

(Synthesized `Codable` uses `decodeIfPresent` for optionals — old history JSON without the key decodes fine; the test proves it.)

- [ ] **Step 4: Make backends throw instead of returning raw text**

`OllamaPolishBackend.swift` — pin temperature in the request body:

```swift
        var body: [String: Any] = [
            "model": config.modelName,
            "prompt": prompt,
            "system": polishSystemInstruction(context: context),
            "stream": false,
            "options": ["temperature": 0.2]
        ]
```

Replace the body of the `do/catch` (lines 63–84) so every failure path throws:

```swift
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
```

Also set `request.timeoutInterval = PipelineTiming.requestTimeout` (replacing the literal 60).

`CloudPolishBackend.swift`:
- `guard config.isConfigured else` (line 26): `throw PolishError.backendUnavailable(displayName)` instead of `return rawText`.
- Rewrite `executeRequest` with the same throw pattern as Ollama above (invalid response type → `.network("invalid response")`, non-200 → `.httpError`, parser nil → `.parseFailure`, catch → rethrow `PolishError` / wrap others in `.network`). Remove the now-unused `rawText` parameter and its call-site arguments.
- Fix the Claude parser to find the first TEXT block (a thinking block can come first):

```swift
    private func parseClaudeResponse(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { return nil }
        return content.first { ($0["type"] as? String) == "text" }?["text"] as? String
    }
```

- Pin temperature: add `"temperature": 0.2` to both the Claude and OpenAI request body dictionaries.
- Both `request.timeoutInterval` literals become `PipelineTiming.requestTimeout`.

`ApplePolishBackend.swift` — in its catch block (lines 45–48 per the current file), `throw PolishError.backendUnavailable("Apple Intelligence: \(error.localizedDescription)")` instead of returning `rawText`. If `isAvailable` is false at the top of `polish`, throw `.backendUnavailable(displayName)`.

- [ ] **Step 5: Pipeline catches, falls back visibly, honors polishEnabled**

In `TranscriptionPipeline.swift`, add below `polishInstruction`:

```swift
    /// When false, skip the polish stage entirely and paste raw transcription.
    public var polishEnabled: Bool = true
```

Replace the polish section of `stop()` (the `state = .polishing` through `TranscriptionResult` creation, lines 74–85) with:

```swift
                var polishedText = rawText
                var polishError: String? = nil

                if polishEnabled {
                    await MainActor.run { state = .polishing }
                    logger.notice("Polishing text...")
                    do {
                        polishedText = try await polishService.polish(
                            rawText,
                            instruction: polishInstruction,
                            context: context ?? PolishContext()
                        )
                    } catch {
                        logger.error("Polish failed, pasting raw text: \(error.localizedDescription)")
                        polishError = error.localizedDescription
                    }
                }

                let result = TranscriptionResult(rawText: rawText, polishedText: polishedText, polishError: polishError)
                await MainActor.run { state = .done(result) }
```

Note the outer `catch` in `stop()` now only handles STT errors — polish failures no longer reach it.

- [ ] **Step 6: Run tests, build, commit**

Run: `rtk swift test 2>&1 | tail -10` — expected: all PASS.
Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add TalkAICore/
rtk git commit -m "fix: polish failures throw and surface via TranscriptionResult.polishError; pin temperature 0.2; align timeouts"
```

---

### Task 4: TranscriptionBackend protocol + injectable pipeline

**Files:**
- Create: `TalkAICore/Sources/TalkAICore/TranscriptionBackend.swift`
- Modify: `TalkAICore/Sources/TalkAICore/SpeechService.swift`, `TranscriptionPipeline.swift`
- Test: `TalkAICore/Tests/TalkAICoreTests/PipelineTests.swift`

**Interfaces:**
- Produces (used by Tasks 5, 8):

```swift
public protocol TranscriptionBackend: AnyObject, Sendable {
    func startCapture() async throws
    /// hotwordPrompt: optional glossary line biasing recognition (Whisper only; Apple ignores it).
    func stopCapture(hotwordPrompt: String?) async throws -> String
    func cancelCapture() async
}
```

  - `TranscriptionPipeline.init(sttBackend: any TranscriptionBackend = SpeechService(), backend: any PolishBackend = ApplePolishBackend())`
  - `TranscriptionPipeline.setSTTBackend(_:)` (no-op unless state is idle)
  - `TranscriptionPipeline.hotwordPrompt: String?` — set by coordinator before `stop()`.

- [ ] **Step 1: Write the failing test**

Create `TalkAICore/Tests/TalkAICoreTests/PipelineTests.swift`:

```swift
import Foundation
import Testing
@testable import TalkAICore

final class FakeSTT: TranscriptionBackend, @unchecked Sendable {
    var transcript = "um hello world"
    var receivedHotwords: String?
    func startCapture() async throws {}
    func stopCapture(hotwordPrompt: String?) async throws -> String {
        receivedHotwords = hotwordPrompt
        return transcript
    }
    func cancelCapture() async {}
}

final class FakePolish: PolishBackend, @unchecked Sendable {
    var result: Result<String, PolishError> = .success("Hello, world.")
    var isAvailable: Bool { get async { true } }
    var supportsVision: Bool { false }
    var displayName: String { "Fake" }
    func polish(_ rawText: String, instruction: String, context: PolishContext) async throws -> String {
        try result.get()
    }
}

@MainActor
struct PipelineTests {
    private func run(_ pipeline: TranscriptionPipeline) async -> TranscriptionResult? {
        await pipeline.start()
        pipeline.stop()
        for _ in 0..<200 {
            if case .done(let r) = pipeline.state { return r }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func successfulPolishProducesCleanResult() async {
        let pipeline = TranscriptionPipeline(sttBackend: FakeSTT(), backend: FakePolish())
        let result = await run(pipeline)
        #expect(result?.polishedText == "Hello, world.")
        #expect(result?.polishError == nil)
    }

    @Test func polishFailureFallsBackToRawWithError() async {
        let polish = FakePolish()
        polish.result = .failure(.backendUnavailable("Fake"))
        let pipeline = TranscriptionPipeline(sttBackend: FakeSTT(), backend: polish)
        let result = await run(pipeline)
        #expect(result?.polishedText == "um hello world")
        #expect(result?.polishError != nil)
    }

    @Test func polishDisabledSkipsBackend() async {
        let polish = FakePolish()
        polish.result = .failure(.backendUnavailable("Fake"))  // would fail if called
        let pipeline = TranscriptionPipeline(sttBackend: FakeSTT(), backend: polish)
        pipeline.polishEnabled = false
        let result = await run(pipeline)
        #expect(result?.polishedText == "um hello world")
        #expect(result?.polishError == nil)
    }

    @Test func hotwordPromptReachesSTTBackend() async {
        let stt = FakeSTT()
        let pipeline = TranscriptionPipeline(sttBackend: stt, backend: FakePolish())
        pipeline.hotwordPrompt = "Glossary: Kaleido."
        _ = await run(pipeline)
        #expect(stt.receivedHotwords == "Glossary: Kaleido.")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk swift test --filter PipelineTests 2>&1 | tail -20`
Expected: FAIL — `TranscriptionBackend` not found, no matching initializer

- [ ] **Step 3: Create the protocol and conform SpeechService**

Create `TalkAICore/Sources/TalkAICore/TranscriptionBackend.swift` with the protocol exactly as in Interfaces above (with doc comments).

In `SpeechService.swift`, change the class declaration (drop `@Observable` — nothing observes it):

```swift
public final class SpeechService: TranscriptionBackend, @unchecked Sendable {
```

Add the protocol method as a thin wrapper next to the existing `stopCapture()`:

```swift
    /// TranscriptionBackend conformance. Apple's SpeechTranscriber has no
    /// hotword-biasing API; the prompt is ignored here (Whisper uses it).
    public func stopCapture(hotwordPrompt: String?) async throws -> String {
        try await stopCapture()
    }
```

- [ ] **Step 4: Inject the backend into TranscriptionPipeline**

In `TranscriptionPipeline.swift`:

```swift
    private var sttBackend: any TranscriptionBackend
    public let polishService: PolishService
    private var processingTask: Task<Void, Never>?

    public var polishInstruction: String = PolishService.defaultInstruction
    public var polishEnabled: Bool = true

    /// Glossary line biasing STT recognition. Set before stop().
    public var hotwordPrompt: String?

    public var context: PolishContext?

    public init(
        sttBackend: any TranscriptionBackend = SpeechService(),
        backend: any PolishBackend = ApplePolishBackend()
    ) {
        self.sttBackend = sttBackend
        self.polishService = PolishService(backend: backend)
    }

    /// Swap the STT engine. Ignored while recording/processing.
    public func setSTTBackend(_ backend: any TranscriptionBackend) {
        guard case .idle = state else { return }
        sttBackend = backend
    }

    /// Update the locale used for speech recognition (Apple backend only).
    public func setLocale(_ locale: Locale) {
        (sttBackend as? SpeechService)?.locale = locale
    }
```

Replace every remaining `speechService.` reference: `startCapture()` call in `start()` becomes `try await sttBackend.startCapture()`; in `stop()` use `try await sttBackend.stopCapture(hotwordPrompt: hotwordPrompt)`; in `cancel()` use `await sttBackend.cancelCapture()`. Delete the old `speechService` property and the `locale:` init parameter (callers use `setLocale`).

CALLER FIX: `TalkAIApp.swift:31` constructs `TranscriptionPipeline()` — still valid (defaults). No change needed yet.

- [ ] **Step 5: Run tests, build, commit**

Run: `rtk swift test 2>&1 | tail -10` — expected: all PASS.
Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add TalkAICore/
rtk git commit -m "refactor: pluggable TranscriptionBackend protocol; pipeline accepts injected STT engine"
```

---

### Task 5: WhisperKit dependency + WhisperService

**Files:**
- Modify: `Package.swift` (root), `build-app.sh`
- Create: `TalkAICore/Sources/TalkAICore/WhisperService.swift`
- Test: `TalkAICore/Tests/TalkAICoreTests/WhisperAudioRecorderTests.swift`

**Interfaces:**
- Consumes: `TranscriptionBackend` (Task 4).
- Produces (used by Tasks 8, 9):
  - `WhisperService(modelName: String, language: String?)` conforming to `TranscriptionBackend`.
  - `WhisperService.preloadModel() async throws` — triggers model download/compile; Settings calls it for the download button.
  - `WhisperModelOption: String, CaseIterable` enum — rawValue is the WhisperKit model name, `.label` for UI.

- [ ] **Step 1: Add WhisperKit to root Package.swift**

```swift
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
```

and in the TalkAICore target:

```swift
        .target(
            name: "TalkAICore",
            dependencies: [.product(name: "WhisperKit", package: "whisperkit")],
            path: "TalkAICore/Sources/TalkAICore"
        ),
```

Run: `rtk swift build 2>&1 | tail -5` — expected: dependency resolves and package builds. If the product/package name capitalization is rejected, check `rtk grep -r "name:" .build/checkouts/WhisperKit/Package.swift` and match it.

- [ ] **Step 2: Write the failing recorder test**

The recorder is the testable core (format conversion + accumulation). Create `TalkAICore/Tests/TalkAICoreTests/WhisperAudioRecorderTests.swift`:

```swift
import AVFoundation
import Testing
@testable import TalkAICore

struct WhisperAudioRecorderTests {
    @Test func accumulatesConvertedSamplesAt16kMono() throws {
        let recorder = WhisperAudioRecorder()
        // Simulate 48kHz stereo hardware input: 4800 frames = 100 ms
        let hwFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: hwFormat, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        recorder.prepare(inputFormat: hwFormat)
        recorder.append(buffer)
        let samples = recorder.finish()
        // 100 ms at 16 kHz mono ≈ 1600 samples (converter may emit ±a few frames)
        #expect(abs(samples.count - 1_600) < 32)
    }

    @Test func finishResetsState() {
        let recorder = WhisperAudioRecorder()
        let hwFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        recorder.prepare(inputFormat: hwFormat)
        _ = recorder.finish()
        #expect(recorder.finish().isEmpty)
    }
}
```

Run: `rtk swift test --filter WhisperAudioRecorderTests 2>&1 | tail -10`
Expected: FAIL — `WhisperAudioRecorder` not found

- [ ] **Step 3: Implement WhisperService.swift**

```swift
@preconcurrency import AVFoundation
import Foundation
import WhisperKit
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Whisper")

/// Whisper model choices exposed in Settings. rawValue is the WhisperKit model name.
public enum WhisperModelOption: String, CaseIterable, Sendable {
    case baseEn = "base.en"
    case smallEn = "small.en"
    case small = "small"
    case medium = "medium"
    case largeTurbo = "large-v3_turbo"

    public var label: String {
        switch self {
        case .baseEn: "Base (English) — fastest, ~150 MB"
        case .smallEn: "Small (English) — ~500 MB"
        case .small: "Small (multilingual) — ~500 MB"
        case .medium: "Medium (multilingual) — ~1.5 GB"
        case .largeTurbo: "Large v3 Turbo — best, ~1.6 GB"
        }
    }
}

/// Accumulates microphone audio as 16 kHz mono Float32 — Whisper's input format.
final class WhisperAudioRecorder: @unchecked Sendable {
    static let whisperSampleRate: Double = 16_000
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: whisperSampleRate, channels: 1, interleaved: false
    )!

    func prepare(inputFormat: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        samples = []
        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var fed = false
        converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples = []
        converter = nil
        return result
    }
}

enum WhisperServiceError: Error, LocalizedError {
    case modelNotLoaded
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not downloaded yet. Open Settings → General to download it."
        case .microphonePermissionDenied: "Microphone permission is required. Please grant access in System Settings."
        }
    }
}

/// Local Whisper transcription via WhisperKit (CoreML). Supports hotword
/// biasing through the decoder prompt — Apple's engine has no equivalent.
public final class WhisperService: TranscriptionBackend, @unchecked Sendable {
    private let modelName: String
    private let language: String?
    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private let recorder = WhisperAudioRecorder()

    public init(modelName: String = WhisperModelOption.baseEn.rawValue, language: String? = "en") {
        self.modelName = modelName
        self.language = language
    }

    /// Downloads (if needed) and loads the CoreML model. Idempotent.
    public func preloadModel() async throws {
        guard whisperKit == nil else { return }
        logger.notice("Loading Whisper model: \(self.modelName)")
        whisperKit = try await WhisperKit(WhisperKitConfig(model: modelName))
        logger.notice("Whisper model ready")
    }

    public func startCapture() async throws {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw WhisperServiceError.microphonePermissionDenied }

        // Kick off model load concurrently with recording — usually cached.
        Task { try? await self.preloadModel() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        recorder.prepare(inputFormat: format)
        let recorder = self.recorder
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            recorder.append(buffer)
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
    }

    public func stopCapture(hotwordPrompt: String?) async throws -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        let samples = recorder.finish()
        guard !samples.isEmpty else { return "" }

        try await preloadModel()
        guard let whisperKit else { throw WhisperServiceError.modelNotLoaded }

        var options = DecodingOptions()
        options.language = language
        options.temperature = 0
        options.skipSpecialTokens = true
        if let prompt = hotwordPrompt, let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !tokens.isEmpty {
                options.promptTokens = tokens
                options.usePrefillPrompt = true
            }
        }

        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancelCapture() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        _ = recorder.finish()
    }
}
```

NAME CLASH WARNING: WhisperKit also declares a `TranscriptionResult`. Inside this file that's fine (we don't reference ours). If ambiguity errors appear elsewhere, qualify as `TalkAICore.TranscriptionResult`.

- [ ] **Step 4: Run recorder tests**

Run: `rtk swift test --filter WhisperAudioRecorderTests 2>&1 | tail -10`
Expected: PASS (2 tests)

- [ ] **Step 5: Copy SPM resource bundles into the app**

`build-app.sh` copies ONLY the binary — WhisperKit ships resource bundles that must live in `Contents/Resources`. After the binary-copy block in `build-app.sh`, add:

```bash
# Copy SPM resource bundles (WhisperKit tokenizer/config resources)
for bundle in .build/debug/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done
```

- [ ] **Step 6: Build and commit**

Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add Package.swift Package.resolved build-app.sh TalkAICore/
rtk git commit -m "feat: WhisperKit-based WhisperService with hotword prompt biasing"
```

---

### Task 6: OCRService (screen text extraction)

**Files:**
- Create: `TalkAICore/Sources/TalkAICore/OCRService.swift`
- Test: `TalkAICore/Tests/TalkAICoreTests/OCRServiceTests.swift`

**Interfaces:**
- Produces (used by Task 8): `OCRService.recognizeText(in: Data) async -> String?` — PNG data in, newline-joined text lines out, nil on failure. Lives in TalkAICore (not the app target) so it's unit-testable; it only needs `import Vision`, no entitlements. (Spec amendment noted in the spec doc.)

- [ ] **Step 1: Write the failing test**

Create `TalkAICore/Tests/TalkAICoreTests/OCRServiceTests.swift`:

```swift
import AppKit
import Testing
@testable import TalkAICore

struct OCRServiceTests {
    /// Renders text into a bitmap, then OCRs it back.
    private func renderPNG(_ text: String) -> Data {
        let size = NSSize(width: 800, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(
            at: NSPoint(x: 20, y: 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        )
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    @Test func recognizesRenderedText() async {
        let png = renderPNG("Kaleido Project")
        let text = await OCRService.recognizeText(in: png)
        #expect(text?.contains("Kaleido") == true)
    }

    @Test func returnsNilForGarbageData() async {
        let text = await OCRService.recognizeText(in: Data([0x00, 0x01]))
        #expect(text == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `rtk swift test --filter OCRServiceTests 2>&1 | tail -10`
Expected: FAIL — `OCRService` not found

- [ ] **Step 3: Implement OCRService.swift**

```swift
import Foundation
import Vision
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "OCR")

/// On-device text extraction from screenshots via the Vision framework.
/// Independent of Apple Intelligence — works with it disabled.
public enum OCRService {
    /// Recognizes text in PNG image data. Returns newline-joined lines,
    /// or nil when the image is unreadable or contains no text.
    public static func recognizeText(in pngData: Data) async -> String? {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    logger.warning("OCR failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(data: pngData)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    logger.warning("OCR handler failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
```

CONTINUATION SAFETY: `VNImageRequestHandler.perform` throwing means the completion never ran — the two `resume` calls are mutually exclusive. Do not add a third.

- [ ] **Step 4: Run test to verify it passes**

Run: `rtk swift test --filter OCRServiceTests 2>&1 | tail -10`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
rtk git add TalkAICore/
rtk git commit -m "feat: OCRService — Vision-based screen text extraction"
```

---

### Task 7: FocusedFieldReader (app target)

**Files:**
- Create: `TalkAI/FocusedFieldReader.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Task 8): `FocusedFieldReader.focusedFieldText() -> String?` — best-effort AX read; nil when unavailable. App target only (needs the app's Accessibility grant); no unit test — verified in the final manual E2E task.

- [ ] **Step 1: Implement**

Create `TalkAI/FocusedFieldReader.swift`:

```swift
import ApplicationServices
import Cocoa
import os

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "FocusedField")

/// Reads the text content of the currently focused UI element via the
/// Accessibility API. Best-effort: many apps (browsers, Electron) block
/// or partially support AX — every failure path returns nil quietly.
@MainActor
enum FocusedFieldReader {
    private static let maxLength = 2_000

    static func focusedFieldText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else { return nil }

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element as! AXUIElement, kAXValueAttribute as CFString, &value
        ) == .success, let text = value as? String, !text.isEmpty else { return nil }

        // Keep the tail — dictation continues from the end of the field.
        return String(text.suffix(maxLength))
    }
}
```

- [ ] **Step 2: Build and commit**

Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add TalkAI/FocusedFieldReader.swift
rtk git commit -m "feat: FocusedFieldReader — AX read of active input field"
```

---

### Task 8: AppCoordinator wiring — context for everyone, Whisper default

**Files:**
- Modify: `TalkAI/TalkAIApp.swift`

**Interfaces:**
- Consumes: everything above.
- Produces (used by Task 9): `AppCoordinator.switchSTTEngine()`, `AppCoordinator.syncPolishSettings()`, `AppCoordinator.lastPolishError: String?`, `AppCoordinator.currentBackendType: ModelBackendType`.

- [ ] **Step 1: Rewire handleHotkey — capture context always, OCR in background**

Replace the `case .idle:` block of `handleHotkey()` (lines 123–150) with:

```swift
        case .idle:
            // Capture context BEFORE showing the overlay so we read the
            // user's actual working window, not ours.
            let metadata = screenshotService.activeAppMetadata()
            let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            let fieldText = FocusedFieldReader.focusedFieldText()
            let wantsScreenContext = useScreenshotContext
            let backendSupportsVision = pipeline.polishService.backend.supportsVision

            // Metadata-only context is available immediately.
            pipeline.context = PolishContext(
                appName: metadata.appName,
                windowTitle: metadata.windowTitle,
                focusedFieldText: fieldText,
                appBundleID: bundleID
            )
            pipeline.hotwordPrompt = nil

            if wantsScreenContext {
                // Screenshot must happen before recording begins;
                // OCR runs while the user is speaking.
                contextTask = Task { [weak self] in
                    guard let self else { return }
                    let screenshot = await screenshotService.captureActiveWindow()
                    var screenText: String?
                    if let screenshot {
                        screenText = await OCRService.recognizeText(in: screenshot)
                    }
                    let hotwords = screenText.map { HotwordExtractor.extract(from: $0) } ?? []
                    pipeline.context = PolishContext(
                        appName: metadata.appName,
                        windowTitle: metadata.windowTitle,
                        screenshot: backendSupportsVision ? screenshot : nil,
                        screenText: screenText,
                        focusedFieldText: fieldText,
                        appBundleID: bundleID
                    )
                    pipeline.hotwordPrompt = HotwordExtractor.prompt(from: hotwords)
                }
            }

            overlayController.show(pipeline: pipeline)
            recordingTask = Task {
                await pipeline.start()
            }
```

Add the property next to `recordingTask`:

```swift
    private var contextTask: Task<Void, Never>?
```

- [ ] **Step 2: Await context before stopping**

Replace `stopAndProcess()`:

```swift
    private func stopAndProcess() {
        Task {
            // Ensure OCR/hotwords finished before transcription consumes them.
            await contextTask?.value
            contextTask = nil
            pipeline.stop()

            let result = await waitForPipelineResult()

            if let result {
                logger.info("Got result, polished: \(result.polishedText)")
                lastPolishError = result.polishError
                historyStore.add(result)

                await pasteManager.paste(result.polishedText)
                try? await Task.sleep(for: .seconds(1.5))
            }

            overlayController.hide()
            pipeline.reset()
        }
    }
```

Add near `menuBarIcon`:

```swift
    /// Error message from the most recent polish failure (raw text was pasted).
    var lastPolishError: String?
```

In `handleCancel()`, also cancel and clear `contextTask`:

```swift
        contextTask?.cancel()
        contextTask = nil
```

- [ ] **Step 3: Fix the wait timeout**

In `waitForPipelineResult()` replace the loop bound and comment:

```swift
        let iterations = Int(PipelineTiming.resultWaitTimeout / 0.05)
        for _ in 0..<iterations { // exceeds backend requestTimeout — late results are never dropped
```

- [ ] **Step 4: STT engine switching + polish settings sync**

Add to `AppCoordinator`:

```swift
    var currentBackendType: ModelBackendType {
        ModelBackendType(rawValue: UserDefaults.standard.string(forKey: "modelBackendType") ?? "") ?? .apple
    }

    /// Rebuild the STT backend from settings. Whisper is the default.
    func switchSTTEngine() {
        let engine = UserDefaults.standard.string(forKey: "sttEngine") ?? "whisper"
        if engine == "apple" {
            let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"
            let apple = SpeechService(locale: Locale(identifier: lang))
            pipeline.setSTTBackend(apple)
        } else {
            let model = UserDefaults.standard.string(forKey: "whisperModel") ?? WhisperModelOption.baseEn.rawValue
            let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "en-US"
            let whisperLang = String(lang.prefix(2))  // "en-US" → "en"
            pipeline.setSTTBackend(WhisperService(modelName: model, language: whisperLang))
        }
        logger.notice("STT engine: \(engine)")
    }

    /// Sync polish enablement from settings.
    func syncPolishSettings() {
        pipeline.polishEnabled = UserDefaults.standard.object(forKey: "polishEnabled") as? Bool ?? true
    }
```

In `init()`, after `startPermissionMonitor()`:

```swift
        switchSTTEngine()
        syncPolishSettings()
        switchBackend(to: currentBackendType)
```

SpeechService init signature check: after Task 4 removed the pipeline's `locale:` param, `SpeechService(locale:)` still exists — this call is correct.

In `switchBackend(to:)`, update the Ollama default model fallback from `"llama3.2"` to `"qwen2.5:3b"`.

- [ ] **Step 5: Menu bar — polish failure indicator, accurate availability warning**

In `MenuBarView`, replace the `if !coordinator.pipeline.isLLMAvailable` block with:

```swift
        if let polishError = coordinator.lastPolishError {
            Label("Last AI cleanup failed — raw text was pasted", systemImage: "exclamationmark.circle")
            Text(polishError)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if coordinator.currentBackendType == .apple && !coordinator.pipeline.isLLMAvailable {
            Label("Apple Intelligence unavailable — switch Model backend in Settings", systemImage: "exclamationmark.triangle")
        }
```

- [ ] **Step 6: Build and commit**

Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add TalkAI/TalkAIApp.swift
rtk git commit -m "feat: wire context bundle + Whisper STT into coordinator; surface polish failures; fix result-wait timeout"
```

---

### Task 9: Settings UI

**Files:**
- Modify: `TalkAI/SettingsView.swift`

**Interfaces:**
- Consumes: `WhisperModelOption`, `WhisperService.preloadModel()`, `AppCoordinator.switchSTTEngine()`, `syncPolishSettings()`.

- [ ] **Step 1: General tab — STT engine, Whisper model, polish toggle**

In `GeneralTab`, add storage properties:

```swift
    @AppStorage("sttEngine") private var sttEngine = "whisper"
    @AppStorage("whisperModel") private var whisperModel = WhisperModelOption.baseEn.rawValue
    @AppStorage("polishEnabled") private var polishEnabled = true
    @State private var modelDownloadStatus: String?
```

Insert a new section between "Hotkey" and "Language":

```swift
            Section("Transcription Engine") {
                Picker("Engine", selection: $sttEngine) {
                    Text("Whisper (recommended)").tag("whisper")
                    Text("Apple Speech").tag("apple")
                }
                .onChange(of: sttEngine) { _, _ in coordinator.switchSTTEngine() }

                if sttEngine == "whisper" {
                    Picker("Whisper Model", selection: $whisperModel) {
                        ForEach(WhisperModelOption.allCases, id: \.rawValue) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .onChange(of: whisperModel) { _, _ in
                        coordinator.switchSTTEngine()
                        downloadModel()
                    }

                    HStack {
                        Button("Download / Verify Model") { downloadModel() }
                        if let status = modelDownloadStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Models download once (from Hugging Face) and then run fully offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
```

Rename the "AI Cleanup Prompt" section header to "AI Cleanup" and add the toggle at its top:

```swift
                Toggle("Polish with AI", isOn: $polishEnabled)
                    .onChange(of: polishEnabled) { _, _ in coordinator.syncPolishSettings() }
                Text("When off, the raw transcription is pasted directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
```

Add the helper to `GeneralTab`:

```swift
    private func downloadModel() {
        modelDownloadStatus = "Downloading…"
        let service = WhisperService(modelName: whisperModel, language: nil)
        Task {
            do {
                try await service.preloadModel()
                modelDownloadStatus = "Ready"
            } catch {
                modelDownloadStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }
```

- [ ] **Step 2: Model tab — defaults and copy**

In `ModelTab`:
- Change `@AppStorage("ollamaModel") private var ollamaModel = "llama3.2"` default to `"qwen2.5:3b"`.
- Update the toggle label from `"Use screenshot context"` to `"Use screen context"` and replace its caption:

```swift
                Text("Captures your active window, extracts on-screen text on-device, and uses it to correct names and technical terms — with every backend. Requires Screen Recording permission.")
```

- [ ] **Step 3: Permissions tab copy**

In `PermissionsTab`, update the Apple Intelligence row description to `"Only needed for the Apple On-Device polish backend"`.

- [ ] **Step 4: Build and commit**

Run: `rtk swift build 2>&1 | tail -5` — expected: Build complete.

```bash
rtk git add TalkAI/SettingsView.swift
rtk git commit -m "feat: settings for STT engine, Whisper model download, polish toggle; qwen2.5:3b default"
```

---

### Task 10: Full build + manual E2E verification

**Files:**
- Modify: none (verification only)

- [ ] **Step 1: Run the complete test suite**

Run: `rtk swift test 2>&1 | tail -15`
Expected: ALL tests pass (HotwordExtractor, PromptBuilder, PolishError, Pipeline, WhisperAudioRecorder, OCRService).

- [ ] **Step 2: Assemble the app bundle (single deliberate rebuild)**

Run: `./build-app.sh`
Expected: `Built: .build/app/TalkAI.app`. This is the ONE binary change of the whole plan — the user must re-grant Accessibility + Screen Recording if macOS revoked them.

- [ ] **Step 3: Prepare the polish model**

Run: `rtk ollama list` — if `qwen2.5:3b` is absent, run `rtk ollama pull qwen2.5:3b`.

- [ ] **Step 4: Manual E2E checklist (user drives; report results honestly)**

1. Launch `.build/app/TalkAI.app`; Settings → General; confirm Engine = Whisper; click "Download / Verify Model"; wait for "Ready".
2. Settings → Model: backend = Ollama, model = `qwen2.5:3b`, "Use screen context" ON.
3. Open a code editor showing an unusual identifier (e.g. `polishSystemInstruction`). Dictate a sentence speaking that identifier aloud. Verify the pasted text spells it exactly as on screen. ← the headline Vibing behavior
4. Dictate "send it Tuesday no wait Thursday" — verify polish keeps only Thursday.
5. Toggle "Polish with AI" OFF; dictate again; verify raw Whisper text pastes (fast, unpolished).
6. Quit Ollama; with polish ON, dictate; verify raw text pastes AND the menu bar shows "Last AI cleanup failed".
7. Dictate into Slack (or Messages) vs. TextEdit and compare tone handling.
8. ESC during recording — verify clean cancel.

- [ ] **Step 5: Commit any fixes found during verification**

```bash
rtk git add -A
rtk git commit -m "chore: E2E fixes from manual verification"
```

---

## Deviations from spec (amended in spec doc)

1. **WhisperKit instead of whisper.cpp** — whisper.cpp removed SPM support (no `Package.swift` in the repo; xcframework-only builds). WhisperKit is SPM-native, CoreML/ANE-accelerated, supports decoder prompt biasing and in-app model downloads. Same design intent, and it integrates with this Xcode-project-less build.
2. **OCRService lives in TalkAICore, not the app target** — Vision needs no entitlements and this placement makes OCR unit-testable with rendered fixture images.
