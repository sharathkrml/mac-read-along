import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

/// A captured frame of an external window: a grayscale thumbnail used to
/// detect visible change cheaply, plus the recognized lines. `lines` is nil
/// when the frame matched the previous thumbnail, so OCR was skipped.
struct CapturedSurface: Sendable {
    let lines: [OCRLine]?
    let thumb: [UInt8]
}

enum WindowCaptureError: LocalizedError, Equatable {
    case windowNotFound
    case recognitionFailed

    var errorDescription: String? {
        switch self {
        case .windowNotFound:
            return "The window is no longer on screen."
        case .recognitionFailed:
            return "Text recognition failed on the captured frame."
        }
    }
}

/// Still-frame capture of another app's window and OCR of its text. Runs
/// entirely off the main actor; only Sendable results come back.
enum WindowCapture {
    static let thumbWidth = 64
    static let thumbHeight = 36

    /// Captures the window and downscales it to a thumbnail. OCR runs only
    /// when the thumbnail differs meaningfully from `previousThumb` (or
    /// `force` is set): a still window costs a capture, not a Vision pass,
    /// and recognition is the expensive part.
    nonisolated static func capture(
        windowID: CGWindowID,
        previousThumb: [UInt8]?,
        force: Bool
    ) async throws -> CapturedSurface {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw WindowCaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        // SCStreamConfiguration defaults to 1920x1080; a differently shaped
        // window gets letterboxed, so normalized rects no longer map back onto
        // the window and highlights drift left of their text. Match the
        // window's pixel size exactly.
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let thumb = grayscaleThumb(image)
                    let lines = FrameDifference.needsRecognition(
                        previous: previousThumb,
                        current: thumb,
                        force: force
                    ) ? try recognize(image) : nil
                    continuation.resume(returning: CapturedSurface(lines: lines, thumb: thumb))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// shortcut: one Vision observation treated as one visual line; column
    /// layouts that Vision merges into single observations will mis-group —
    /// revisit if multi-column reading surfaces matter.
    private nonisolated static func recognize(_ image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        var lines: [OCRLine] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            var words: [OCRWord] = []
            for range in SentenceIndex.wordRanges(in: candidate.string) {
                guard let box = try? candidate.boundingBox(for: range) else {
                    // Partial word geometry would misalign every later word;
                    // drop it for the whole line and fall back to line rects.
                    words = []
                    break
                }
                words.append(OCRWord(
                    range: NSRange(range, in: candidate.string),
                    rect: box.boundingBox
                ))
            }
            lines.append(OCRLine(
                text: candidate.string,
                rect: observation.boundingBox,
                words: words
            ))
        }
        return lines
    }

    private nonisolated static func grayscaleThumb(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: thumbWidth * thumbHeight)
        let written = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: thumbWidth,
                height: thumbHeight,
                bitsPerComponent: 8,
                bytesPerRow: thumbWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbWidth, height: thumbHeight))
            return true
        }
        return written ? pixels : []
    }
}

/// Cheap change detector between two captures of the same window.
enum FrameDifference {
    /// Mean absolute difference of two grayscale thumbnails, 0…255. Real text
    /// movement (a scroll) lands well above 2; cursor blinks and antialiasing
    /// noise stay below it.
    static func score(_ left: [UInt8], _ right: [UInt8]) -> Double {
        guard !left.isEmpty, left.count == right.count else { return .infinity }
        let total = zip(left, right).reduce(0) { sum, pair in
            sum + abs(Int(pair.0) - Int(pair.1))
        }
        return Double(total) / Double(left.count)
    }

    static func isMeaningfulChange(_ score: Double) -> Bool {
        score > 2
    }

    /// Whether a captured frame needs a Vision pass: always when forced,
    /// otherwise only when the pixels moved enough to be worth reading again.
    static func needsRecognition(previous: [UInt8]?, current: [UInt8], force: Bool) -> Bool {
        force || isMeaningfulChange(score(previous ?? [], current))
    }
}
