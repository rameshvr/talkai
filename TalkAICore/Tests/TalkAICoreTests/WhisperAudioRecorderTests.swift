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
