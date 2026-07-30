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
