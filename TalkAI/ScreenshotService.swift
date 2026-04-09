import Cocoa
import ScreenCaptureKit
import os
import TalkAICore

private let logger = Logger(subsystem: "com.talkai.TalkAI", category: "Screenshot")

/// Captures screenshots and active window metadata.
@MainActor
final class ScreenshotService {

    /// Get metadata about the active application.
    func activeAppMetadata() -> (appName: String?, windowTitle: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName

        var windowTitle: String?
        if let pid = app?.processIdentifier {
            let appRef = AXUIElementCreateApplication(pid)
            var focusedWindow: AnyObject?
            AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
            if let window = focusedWindow {
                var titleValue: AnyObject?
                AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
                windowTitle = titleValue as? String
            }
        }

        logger.notice("Active app: \(appName ?? "unknown"), window: \(windowTitle ?? "unknown")")
        return (appName, windowTitle)
    }

    /// Capture the frontmost window as PNG data using ScreenCaptureKit.
    func captureActiveWindow() async -> Data? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            logger.warning("No frontmost application found")
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let appPID = frontApp.processIdentifier

            guard let window = content.windows.first(where: {
                $0.owningApplication?.processID == appPID && $0.isOnScreen
            }) else {
                logger.warning("No matching window found for PID \(appPID)")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = min(Int(window.frame.width) * 2, 2048)
            config.height = min(Int(window.frame.height) * 2, 2048)

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            let resized = downsample(nsImage, maxDimension: 1024)

            guard let tiffData = resized.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                logger.warning("Failed to convert image to PNG")
                return nil
            }

            logger.notice("Captured window screenshot: \(pngData.count) bytes")
            return pngData
        } catch {
            logger.warning("Screenshot capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if Screen Recording permission is granted.
    var hasScreenRecordingPermission: Bool {
        get async {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                return true
            } catch {
                return false
            }
        }
    }

    private func downsample(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}
