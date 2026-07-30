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
