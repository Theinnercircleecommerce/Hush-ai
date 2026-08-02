//
//  ScreenCaptureService.swift
//  Hush
//
//  Multi-display screen capture for the circle-to-ask flow. Captures every
//  connected display (excluding Hush's own windows), downscales, and provides
//  a crop from a global AppKit rect (the circle overlay's bounding box) into
//  the correct screenshot's pixel space.
//

import AppKit
import ImageIO
import ScreenCaptureKit

/// One captured display, ready to hand to a vision model.
struct CapturedScreen {
    let jpeg: Data
    let label: String           // "screen 1 of 2 (cursor here)"
    let isCursorScreen: Bool
    let displayFrame: CGRect     // AppKit global, bottom-left origin
    let pixelSize: CGSize        // screenshot pixels
}

/// Error surfaced when Screen Recording permission is missing. The message is
/// safe to show to the user verbatim.
struct ScreenCaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ScreenCaptureService {

    private static let maxLongEdge = 1280
    private static let jpegQuality: CGFloat = 0.8

    /// Captures every connected display, excluding the given windows (Hush's
    /// own overlays/panels). The cursor's screen is sorted first. Throws a
    /// `ScreenCaptureError` with a user-facing message if Screen Recording is
    /// not permitted.
    static func captureAll(excluding windows: [NSWindow]) async throws -> [CapturedScreen] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            // SCShareableContent throws when Screen Recording is not granted.
            throw ScreenCaptureError(
                message: "enable screen recording for Hush in system settings"
            )
        }

        guard !content.displays.isEmpty else {
            throw ScreenCaptureError(
                message: "enable screen recording for Hush in system settings"
            )
        }

        let mouseLocation = NSEvent.mouseLocation

        // Map the passed NSWindows to SCWindows by windowID so we exclude
        // exactly Hush's own windows from the capture.
        let excludeWindowIDs = Set(windows.map { CGWindowID($0.windowNumber) })
        let excludedSCWindows = content.windows.filter {
            excludeWindowIDs.contains($0.windowID)
        }

        // SCDisplay.frame is CoreGraphics top-left-origin global space, but the
        // overlay's rect (and NSEvent.mouseLocation) live in AppKit bottom-left
        // global space. Map each display to its NSScreen and use NSScreen.frame
        // as the displayFrame so everything downstream stays consistent.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[number] = screen
            }
        }

        func appKitFrame(for display: SCDisplay) -> CGRect {
            nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
        }

        // Cursor's screen first.
        let sortedDisplays = content.displays.sorted { a, b in
            let aHasCursor = appKitFrame(for: a).contains(mouseLocation)
            let bHasCursor = appKitFrame(for: b).contains(mouseLocation)
            if aHasCursor != bHasCursor { return aHasCursor }
            return false
        }

        var results: [CapturedScreen] = []

        for (index, display) in sortedDisplays.enumerated() {
            let displayFrame = appKitFrame(for: display)
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: excludedSCWindows)

            let configuration = SCStreamConfiguration()
            let longEdge = max(display.width, display.height)
            let aspect = CGFloat(display.width) / CGFloat(display.height)
            if longEdge > maxLongEdge {
                if display.width >= display.height {
                    configuration.width = maxLongEdge
                    configuration.height = Int((CGFloat(maxLongEdge) / aspect).rounded())
                } else {
                    configuration.height = maxLongEdge
                    configuration.width = Int((CGFloat(maxLongEdge) * aspect).rounded())
                }
            } else {
                configuration.width = display.width
                configuration.height = display.height
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpeg = jpegData(from: cgImage) else { continue }

            let total = sortedDisplays.count
            let label: String
            if total == 1 {
                label = "screen 1 of 1 (cursor here)"
            } else if isCursorScreen {
                label = "screen \(index + 1) of \(total) (cursor here)"
            } else {
                label = "screen \(index + 1) of \(total)"
            }

            results.append(CapturedScreen(
                jpeg: jpeg,
                label: label,
                isCursorScreen: isCursorScreen,
                displayFrame: displayFrame,
                pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
            ))
        }

        guard !results.isEmpty else {
            throw ScreenCaptureError(
                message: "enable screen recording for Hush in system settings"
            )
        }

        return results
    }

    /// Crops the given screen's screenshot to the region described by a global
    /// AppKit rect (bottom-left origin, points). Returns nil if the rect does
    /// not intersect this screen. Re-encodes JPEG at quality 0.8.
    static func crop(_ screen: CapturedScreen, toGlobalRect rect: CGRect) -> Data? {
        let displayFrame = screen.displayFrame
        let pixelSize = screen.pixelSize

        // The rect must intersect this screen to belong to it.
        guard displayFrame.intersects(rect) else { return nil }

        // Points -> pixels. Scales can differ per axis in principle; derive both.
        let xScale = pixelSize.width / displayFrame.width
        let yScale = pixelSize.height / displayFrame.height

        // X: offset from the display's left edge, in points, scaled to pixels.
        let pixelX = (rect.minX - displayFrame.minX) * xScale
        let pixelWidth = rect.width * xScale

        // Y: flip from bottom-left points to top-left pixels. The pixel-space Y
        // of the crop's TOP edge is measured down from the display's top edge,
        // which in AppKit points is displayFrame.maxY. rect.maxY is the top of
        // the rect (largest y in bottom-left space).
        let pixelY = (displayFrame.maxY - rect.maxY) * yScale
        let pixelHeight = rect.height * yScale

        var cropRect = CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight)

        // Clamp to the image bounds.
        let bounds = CGRect(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
        cropRect = cropRect.intersection(bounds)
        guard !cropRect.isNull, !cropRect.isEmpty else { return nil }

        // Integralize so cropping lands on whole pixels.
        cropRect = cropRect.integral.intersection(bounds)
        guard !cropRect.isNull, !cropRect.isEmpty else { return nil }

        guard let source = cgImage(from: screen.jpeg),
              let cropped = source.cropping(to: cropRect) else {
            return nil
        }

        return jpegData(from: cropped)
    }

    // MARK: - Encoding helpers

    private static func jpegData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
    }

    private static func cgImage(from jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
