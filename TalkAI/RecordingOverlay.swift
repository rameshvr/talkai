import SwiftUI
import TalkAICore

/// A floating overlay window that shows recording/processing state.
@MainActor
final class OverlayWindowController {
    private var window: NSPanel?

    func show(pipeline: TranscriptionPipeline) {
        if window == nil {
            createWindow(pipeline: pipeline)
        }
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func createWindow(pipeline: TranscriptionPipeline) {
        let contentView = OverlayContentView(pipeline: pipeline)
        let hosting = NSHostingView(rootView: contentView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 50),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = hosting

        // Position near top-center of the main screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 110
            let y = screenFrame.maxY - 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.window = panel
    }
}

struct OverlayContentView: View {
    let pipeline: TranscriptionPipeline

    private var statusText: String {
        switch pipeline.state {
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .polishing: return "Polishing..."
        case .done: return "Pasted!"
        case .error(let msg): return msg
        case .cancelled: return "Cancelled"
        case .idle: return ""
        }
    }

    private var iconName: String {
        switch pipeline.state {
        case .recording: return "mic.fill"
        case .transcribing, .polishing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        default: return "mic"
        }
    }

    private var iconColor: Color {
        switch pipeline.state {
        case .recording: return .red
        case .done: return .green
        case .error: return .yellow
        default: return .white
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16, height: 16)
            Text(statusText)
                .font(.system(.body, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .fixedSize()
    }
}
