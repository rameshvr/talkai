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
