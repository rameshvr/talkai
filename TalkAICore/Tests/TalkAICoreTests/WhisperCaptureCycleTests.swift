import AVFoundation
import Foundation
import Testing
@testable import TalkAICore

/// Counts tap callbacks and frames across threads for capture diagnostics.
final class TapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _taps = 0
    private var _frames = 0
    private var _nilChannelData = 0

    func record(frameLength: Int, hasChannelData: Bool) {
        lock.lock(); defer { lock.unlock() }
        _taps += 1
        _frames += frameLength
        if !hasChannelData { _nilChannelData += 1 }
    }

    var summary: (taps: Int, frames: Int, nilChannelData: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_taps, _frames, _nilChannelData)
    }
}

/// Live mic-capture cycle checks, gated behind TALKAI_SMOKE=1 (needs
/// microphone permission and real audio hardware).
struct WhisperCaptureCycleTests {
    /// Reproduces the "second recording is empty" bug at the AVAudioEngine
    /// level: three consecutive fresh-engine capture cycles, mirroring
    /// WhisperService.startCapture/stopCapture exactly, instrumented at all
    /// three boundaries (tap fires / append drops / finish converts).
    @Test func consecutiveFreshEngineCyclesProduceSamples() async throws {
        guard ProcessInfo.processInfo.environment["TALKAI_SMOKE"] == "1" else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        try #require(granted, "test runner needs microphone permission")

        for cycle in 1...3 {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            print("DIAG cycle \(cycle) pre-prepare format: sr=\(format.sampleRate) ch=\(format.channelCount)")

            let recorder = WhisperAudioRecorder()
            recorder.prepare(inputFormat: format)
            let probe = TapProbe()
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                probe.record(frameLength: Int(buffer.frameLength), hasChannelData: buffer.floatChannelData != nil)
                recorder.append(buffer)
            }
            engine.prepare()
            let postPrepare = input.outputFormat(forBus: 0)
            print("DIAG cycle \(cycle) post-prepare format: sr=\(postPrepare.sampleRate) ch=\(postPrepare.channelCount)")
            try engine.start()
            print("DIAG cycle \(cycle) engine.isRunning=\(engine.isRunning)")
            try await Task.sleep(for: .seconds(1.5))

            input.removeTap(onBus: 0)
            engine.stop()
            let samples = recorder.finish()
            let s = probe.summary
            print("DIAG cycle \(cycle) taps=\(s.taps) frames=\(s.frames) nilChannelData=\(s.nilChannelData) finishedSamples=\(samples.count)")
            #expect(!samples.isEmpty, "cycle \(cycle) produced zero samples")
        }
    }

    /// Reproduces the bug at the WhisperService level: two full
    /// startCapture → stopCapture cycles with the real WhisperKit model load
    /// and transcription in between, exactly like the app's runs 1 and 2.
    @Test func secondWhisperServiceRecordingCapturesAudio() async throws {
        guard ProcessInfo.processInfo.environment["TALKAI_SMOKE"] == "1" else { return }

        let service = WhisperService()
        for cycle in 1...2 {
            try await service.startCapture()
            try await Task.sleep(for: .seconds(1.5))
            let frames = service.capturedFrameCount
            print("DIAG service cycle \(cycle) capturedFrames=\(frames)")
            let transcript = try await service.stopCapture(hotwordPrompt: nil)
            print("DIAG service cycle \(cycle) transcript='\(transcript)'")
            #expect(frames > 0, "cycle \(cycle): recorder captured no frames")
        }
    }
}
