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
            let resumed = OSAllocatedUnfairLock(initialState: false)

            let request = VNRecognizeTextRequest { request, error in
                let shouldResume = resumed.withLock { if $0 { return false }; $0 = true; return true }
                guard shouldResume else { return }

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
                    let shouldResume = resumed.withLock { if $0 { return false }; $0 = true; return true }
                    guard shouldResume else { return }

                    logger.warning("OCR handler failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
