import AppKit
import CoreGraphics

/// Runs a read-along session against an external window: captures and
/// recognizes the window's text, tracks the reader's speech against it, and
/// draws the two-stage highlight through the overlay.
@MainActor
final class SessionController {
    enum State: Equatable {
        case idle
        case picking
        case active(CGWindowID)
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?() }
    }

    var onStateChange: (() -> Void)?

    private let engine: SpeechEngine
    private let picker = WindowPicker()
    private let overlay = SessionOverlay()
    private let tracker = ReadingTracker()

    private var surface: Surface?
    private var lastThumb: [UInt8]?
    private var lastFrameSize: CGSize?
    private var recaptureTask: Task<Void, Never>?
    /// Manual scrolling suppresses auto-scroll until it settles.
    private var manualScrollHoldUntil = Date.distantPast
    /// Recaptures right after our own scroll are self-inflicted, not manual.
    private var lastAutoScrollAt = Date.distantPast

    init(engine: SpeechEngine) {
        self.engine = engine
        tracker.onChange = { [weak self] in self?.render() }
    }

    func toggle() {
        Log.note("toggle; state: \(String(describing: self.state))")
        switch state {
        case .idle:
            beginPicking()
        case .picking:
            cancelPicking()
        case .active:
            end()
        }
    }

    func end() {
        picker.end()
        overlay.end()
        recaptureTask?.cancel()
        recaptureTask = nil
        engine.removeObserver(id: ObjectIdentifier(self))
        engine.stop()
        surface = nil
        lastThumb = nil
        lastFrameSize = nil
        state = .idle
    }

    private func beginPicking() {
        guard ScreenRecordingPermission.ensure() else {
            Log.note("screen recording not granted; staying idle")
            return
        }
        Log.note("screen recording granted; beginning pick")
        state = .picking
        picker.begin(
            onPick: { [weak self] info in self?.attach(to: info) },
            onCancel: { [weak self] in self?.state = .idle }
        )
    }

    private func cancelPicking() {
        picker.end()
        state = .idle
    }

    // MARK: - Session

    private func attach(to info: WindowInfo) {
        Log.note("attached to window \(info.windowID) \(info.ownerName)")
        picker.end()
        state = .active(info.windowID)
        overlay.begin(window: info) { [weak self] in
            self?.end()
        }
        overlay.setNotice("Reading the window…")

        // The engine is shared with the reader window; one stream at a time.
        engine.stop()
        engine.addObserver(
            id: ObjectIdentifier(self),
            onState: { [weak self] state in self?.handleEngineState(state) },
            onTranscript: { [weak self] update in self?.tracker.handle(update) }
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureAndLoad(force: true)
            guard case .active = self.state else { return }
            do {
                try await self.engine.start()
            } catch {
                Log.note("engine start failed: \(error.localizedDescription)")
            }
        }

        // shortcut: 1 fps frame-diff recapture covers scroll, resize and
        // content change; raise toward the 2 fps budget only if reading
        // through page turns feels laggy.
        recaptureTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1000))
                self?.recaptureIfListening()
            }
        }
    }

    private func handleEngineState(_ state: SpeechEngineState) {
        guard case .active = self.state else { return }
        switch state {
        case .listening:
            switch surface?.sentences.isEmpty {
            case false?:
                overlay.setNotice(AutoScroller.isAvailable
                    ? nil
                    : "Auto-scroll needs Accessibility — reading still works")
            case true?:
                overlay.setNotice("No readable text found in this window")
            default:
                overlay.setNotice("Reading the window…")
            }
        case .failed(let message):
            overlay.setNotice(message)
        default:
            break
        }
    }

    // MARK: - Capture and tracking

    private func recaptureIfListening() {
        guard case .active = state, engine.state == .listening else { return }
        Task { @MainActor [weak self] in
            await self?.captureAndLoad(force: false)
        }
    }

    private func captureAndLoad(force: Bool) async {
        guard case .active(let windowID) = state else { return }

        let frame: CapturedSurface
        do {
            frame = try await WindowCapture.capture(windowID: windowID)
        } catch {
            // Transient failures (minimized, mid-move) keep the last surface.
            Log.note("capture failed: \(error.localizedDescription)")
            return
        }

        guard case .active = state,
        let current = WindowInfo.current(windowID: windowID) else { return }

        let contentChanged = force
            || lastThumb == nil
            || FrameDifference.isMeaningfulChange(FrameDifference.score(lastThumb ?? [], frame.thumb))
        let resized = lastFrameSize != current.frame.size
        lastFrameSize = current.frame.size

        guard contentChanged || resized else { return }
        lastThumb = frame.thumb

        // A content change we did not just cause ourselves is the reader
        // scrolling manually: back off from auto-scroll while it settles.
        if contentChanged, !force, Date() > lastAutoScrollAt.addingTimeInterval(0.9) {
            manualScrollHoldUntil = Date().addingTimeInterval(2.5)
        }

        let newSurface = SurfaceBuilder.build(lines: frame.lines)
        surface = newSurface

        if newSurface.sentences.isEmpty {
            tracker.load(sentences: [])
            overlay.setHighlights(nil)
            overlay.setNotice(engine.state == .listening
                ? "No readable text found in this window"
                : "Reading the window…")
            Log.note("capture: no readable text")
        } else {
            tracker.reload(newSurface.sentences)
            overlay.setNotice(nil)
            Log.note("capture: \(newSurface.sentences.count) sentences")
        }
    }

    private func render() {
        guard let surface, !surface.sentences.isEmpty else {
            overlay.setHighlights(nil)
            return
        }

        func rects(at index: Int?) -> [CGRect] {
            guard let index, surface.rects.indices.contains(index) else { return [] }
            return surface.rects[index]
        }

        let cursor = tracker.cursor
        let currentRects = rects(at: cursor)
        overlay.setHighlights(HighlightRects(
            current: currentRects,
            next: rects(at: (cursor ?? -1) + 1)
        ))
        autoScrollIfNeeded(currentRects)
    }

    // MARK: - Auto-scroll

    private func autoScrollIfNeeded(_ rects: [CGRect]) {
        guard !rects.isEmpty,
              case .active(let windowID) = state,
              Date() >= manualScrollHoldUntil,
              AutoScroller.isAvailable,
              let target = WindowInfo.current(windowID: windowID),
              target.ownerPID > 0 else { return }
        let union = rects.dropFirst().reduce(rects[0], { CGRectUnion($0, $1) })

        // Normalized rects use Vision's bottom-left origin; the planner wants
        // top-down distances from the top of the window.
        let height = target.frame.height
        let sentenceTop = (1 - union.maxY) * height
        let sentenceBottom = (1 - union.minY) * height

        guard let pixels = AutoScrollPlanner.scrollDownPixels(
            sentenceTop: sentenceTop,
            sentenceBottom: sentenceBottom,
            viewportHeight: height
        ), pixels > 0 else { return }

        lastAutoScrollAt = Date()
        AutoScroller.scroll(downPixels: pixels, pid: target.ownerPID)
    }
}
