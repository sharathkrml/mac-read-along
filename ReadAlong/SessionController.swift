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
    private let statusCard = StatusCard()

    private var surface: Surface?
    private var lastThumb: [UInt8]?
    private var lastFrameSize: CGSize?
    private var lastRenderedCursor: Int?
    private var recaptureTask: Task<Void, Never>?
    /// Manual scrolling suppresses auto-scroll until it settles.
    private var manualScrollHoldUntil = Date.distantPast
    /// Recaptures right after our own scroll are self-inflicted, not manual.
    private var lastAutoScrollAt = Date.distantPast

    init(engine: SpeechEngine) {
        self.engine = engine
        tracker.onChange = { [weak self] in self?.render() }
        statusCard.onMicrophoneChange = { [weak self] in self?.engine.applyMicrophoneChange() }
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

    /// Starts the picker; the launcher's Start reading button calls this.
    /// No-op unless idle, so it can never end a running session.
    func begin() {
        guard state == .idle else { return }
        beginPicking()
    }

    func end() {
        picker.end()
        overlay.end()
        recaptureTask?.cancel()
        recaptureTask = nil
        engine.removeObserver(id: ObjectIdentifier(self))
        engine.stop()
        statusCard.hide()
        surface = nil
        lastThumb = nil
        lastFrameSize = nil
        lastRenderedCursor = nil
        state = .idle
    }

    /// The menu bar can hide or restore the card mid-session.
    func syncStatusCardVisibility() {
        guard case .active(let windowID) = state,
              AppSettings.standard.cardVisible,
              let target = WindowInfo.current(windowID: windowID) else {
            statusCard.hide()
            return
        }
        if !statusCard.isShown {
            statusCard.show(near: target.frame)
        }
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
        lastRenderedCursor = nil
        state = .active(info.windowID)
        overlay.begin(window: info) { [weak self] in
            self?.end()
        }
        overlay.setNotice("Reading the window…")

        statusCard.onStop = { [weak self] in self?.end() }
        statusCard.onRetry = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.engine.start()
                } catch {
                    Log.note("engine retry failed: \(error.localizedDescription)")
                }
            }
        }
        if AppSettings.standard.cardVisible {
            statusCard.show(near: info.frame)
        }
        statusCard.update(state: .starting("Starting speech engine…"))

        // The engine is shared with the launcher; one stream at a time.
        engine.stop()
        engine.addObserver(
            id: ObjectIdentifier(self),
            onState: { [weak self] state in self?.handleEngineState(state) },
            onTranscript: { [weak self] update in
                self?.tracker.handle(update)
                self?.statusCard.updateTranscript(update.text, isFinal: update.isFinal)
            },
            onLevel: { [weak self] level in self?.statusCard.addLevel(level) }
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
        statusCard.update(state: state)
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
        guard case .active(let windowID) = state,
              let current = WindowInfo.current(windowID: windowID) else { return }

        // A resize changes the line geometry even when the content is the same,
        // so it forces a fresh read; ordinary ticks only re-read on movement.
        let resized = lastFrameSize != current.frame.size
        lastFrameSize = current.frame.size

        let frame: CapturedSurface
        do {
            frame = try await WindowCapture.capture(
                windowID: windowID,
                previousThumb: lastThumb,
                force: force || resized
            )
        } catch {
            // Transient failures (minimized, mid-move) keep the last surface.
            Log.note("capture failed: \(error.localizedDescription)")
            return
        }
        overlay.setTone(SurfaceTone.classify(frame.thumb))

        guard case .active = state, let lines = frame.lines else { return }
        lastThumb = frame.thumb

        // A content change we did not just cause ourselves is the reader
        // scrolling manually: back off from auto-scroll while it settles.
        if !force, !resized, Date() > lastAutoScrollAt.addingTimeInterval(0.9) {
            manualScrollHoldUntil = Date().addingTimeInterval(2.5)
        }

        let newSurface = SurfaceBuilder.build(lines: lines)
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
        if cursor != lastRenderedCursor {
            lastRenderedCursor = cursor
            let detail = cursor.map {
                "\($0) rects=\(surface.rects.indices.contains($0) ? surface.rects[$0].count : -1)"
            } ?? "nil"
            Log.note("cursor: \(detail)")
        }
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
