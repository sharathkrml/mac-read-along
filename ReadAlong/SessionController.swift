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
            if surface?.sentences.isEmpty != false {
                overlay.setNotice("No readable text found in this window")
            } else {
                overlay.setNotice(nil)
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
        overlay.setHighlights(HighlightRects(
            current: rects(at: cursor),
            next: rects(at: (cursor ?? -1) + 1)
        ))
    }
}
