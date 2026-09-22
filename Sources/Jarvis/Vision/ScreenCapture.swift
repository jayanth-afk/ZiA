import Foundation
import CoreGraphics
import ScreenCaptureKit
import AppKit

/// High-performance display and window screenshot capture using modern ScreenCaptureKit (macOS 15+).
/// Runs off MainActor (Guardrail 1).
final class ScreenCapture: @unchecked Sendable {
    static let shared = ScreenCapture()

    private init() {}

    // MARK: - Public API

    /// Captures the main display as compressed JPEG data using ScreenCaptureKit.
    func captureMainDisplay(maxDimension: CGFloat = 1280, compressionQuality: CGFloat = 0.75) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                JarvisLogger.actions.error("ScreenCaptureKit: No active display found")
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return processImage(cgImage, maxDimension: maxDimension, compressionQuality: compressionQuality)
        } catch {
            JarvisLogger.actions.error("ScreenCaptureKit display capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Captures a specific window using ScreenCaptureKit.
    func captureWindow(windowId: CGWindowID, maxDimension: CGFloat = 1280, compressionQuality: CGFloat = 0.75) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowId }) else {
                JarvisLogger.actions.error("ScreenCaptureKit: Window \(windowId) not found")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return processImage(cgImage, maxDimension: maxDimension, compressionQuality: compressionQuality)
        } catch {
            JarvisLogger.actions.error("ScreenCaptureKit window capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private Processing

    private func processImage(_ image: CGImage, maxDimension: CGFloat, compressionQuality: CGFloat) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if max(width, height) > maxDimension {
            let scale = maxDimension / max(width, height)
            targetWidth = width * scale
            targetHeight = height * scale
        } else {
            targetWidth = width
            targetHeight = height
        }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetWidth),
            pixelsHigh: Int(targetHeight),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmap = rep,
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let contextCG = context.cgContext
        contextCG.interpolationQuality = .high
        contextCG.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
