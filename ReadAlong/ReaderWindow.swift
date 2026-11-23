import AppKit
import PDFKit
import UniformTypeIdentifiers

/// The reader window: opens a local text/Markdown file, shows the paper-and-ink
/// reading surface, and follows the reader's voice with a sentence highlight.
@MainActor
final class ReaderController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var textScroll: NSScrollView?
    private var pdfView: PDFView?
    private var pdfHighlight: PDFHighlightView?
    private var pdfSentences: [PDFSentence] = []
    private var isPDF = false
    private var listenButton: NSButton?
    private var statusLabel: NSTextField?
    private var statusDot: NSView?
    private var lastHighlighted = NSRange(location: 0, length: 0)
    private var highlighted = false
    private var isStarting = false
    /// Manual scrolling suppresses auto-scroll until it settles.
    private var manualScrollHoldUntil = Date.distantPast
    /// True while the reader window owns the shared engine's single stream.
    private var readerStreaming = false

    private let tracker = ReadingTracker()
    private let engine: SpeechEngine

    init(engine: SpeechEngine) {
        self.engine = engine
        super.init()
        tracker.onChange = { [weak self] in self?.renderHighlights() }
        engine.addObserver(
            id: ObjectIdentifier(self),
            onState: { [weak self] state in self?.handleEngineState(state) },
            onTranscript: { [weak self] update in self?.handleTranscript(update) }
        )
    }

    private func handleTranscript(_ update: TranscriptUpdate) {
        guard readerStreaming else { return }
        tracker.handle(update)
    }

    func openDocumentPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .text, .pdf]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        engine.stop()
        readerStreaming = false
        isStarting = false

        if url.pathExtension.lowercased() == "pdf" {
            openPDF(url: url)
            return
        }

        let text: String
        do {
            text = try Self.readText(at: url)
        } catch {
            showWindow()
            setStatus("Could not open \(url.lastPathComponent)", color: ReaderTheme.danger)
            return
        }

        showWindow()
        window?.title = url.deletingPathExtension().lastPathComponent
        install(text: text)
        pdfSentences = []
        tracker.load(sentences: SentenceIndex.sentences(in: text))
        clearHighlights()
        setStatus("\(tracker.sentences.count) sentences · press Listen", color: ReaderTheme.textSecondary)
        updateListenButton()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - PDF documents

    private func openPDF(url: URL) {
        guard let document = PDFDocument(url: url) else {
            showWindow()
            setStatus("Could not open \(url.lastPathComponent)", color: ReaderTheme.danger)
            return
        }

        showWindow()
        window?.title = url.deletingPathExtension().lastPathComponent
        installPDF(document)

        let sentences = PDFSurfaceBuilder.build(
            pages: (0..<document.pageCount).map { document.page(at: $0)?.string }
        )
        pdfSentences = sentences
        tracker.load(sentences: sentences.map(\.sentence))

        if sentences.isEmpty {
            // Text-based PDFs only: image-only scans have nothing to track.
            clearHighlights()
            setStatus(
                "No selectable text in this PDF — image-only PDFs are not supported yet",
                color: ReaderTheme.danger
            )
        } else {
            setStatus("\(sentences.count) sentences · press Listen", color: ReaderTheme.textSecondary)
        }
        updateListenButton()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func installPDF(_ document: PDFDocument) {
        isPDF = true
        let view: PDFView
        let highlight: PDFHighlightView
        if let existing = pdfView, let existingHighlight = pdfHighlight {
            view = existing
            highlight = existingHighlight
        } else {
            view = PDFView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.displayDirection = .vertical
            view.displaysPageBreaks = true
            view.autoScales = true
            view.backgroundColor = ReaderTheme.canvas

            highlight = PDFHighlightView(frame: .zero)
            highlight.autoresizingMask = [.width, .height]
            view.addSubview(highlight)

            guard let container = window?.contentView else { return }
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            pdfView = view
            pdfHighlight = highlight

            for name in [
                NSNotification.Name.PDFViewPageChanged,
                NSNotification.Name.PDFViewScaleChanged,
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(pdfLayoutChanged),
                    name: name,
                    object: view
                )
            }
        }

        textScroll?.isHidden = true
        view.isHidden = false
        view.document = document
        // The highlight view is document-glued: track the PDFView's bounds.
        highlight.frame = CGRect(origin: .zero, size: view.bounds.size)
        renderHighlights()
    }

    @objc private func pdfLayoutChanged() {
        if let view = pdfView, let highlight = pdfHighlight {
            highlight.frame = CGRect(origin: .zero, size: view.bounds.size)
        }
        renderHighlights()
    }

    func shutdown() {
        engine.shutdown()
    }

    // MARK: - Window

    private func showWindow() {
        if window == nil {
            window = makeWindow()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Read Along"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ReaderTheme.canvas
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let container = ReaderContainerView()
        container.controller = self
        container.wantsLayer = true
        container.layer?.backgroundColor = ReaderTheme.canvas.cgColor
        container.registerForDraggedTypes([.fileURL])
        window.contentView = container

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 96, right: 0)
        textScroll = scroll

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = ReaderTheme.textPrimary
        textView.font = ReaderTheme.readingFont()
        textView.textContainerInset = NSSize(width: 52, height: 44)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        self.textView = textView

        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = ReaderTheme.surfaceRaised.cgColor
        card.layer?.cornerRadius = 16
        card.layer?.borderWidth = 1
        card.layer?.borderColor = ReaderTheme.readingStroke.withAlphaComponent(0.16).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -6)
        card.layer?.masksToBounds = false

        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = ReaderTheme.textSecondary.cgColor
        statusDot = dot

        let status = NSTextField(labelWithString: "Open a text or Markdown file")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = ReaderTheme.interfaceFont(size: 12)
        status.textColor = ReaderTheme.textSecondary
        status.lineBreakMode = .byTruncatingTail
        statusLabel = status

        let button = NSButton(title: "Listen", target: self, action: #selector(toggleListening))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = ReaderTheme.readingStroke.cgColor
        button.layer?.cornerRadius = 9
        button.font = ReaderTheme.interfaceFont(size: 13, weight: .semibold)
        button.contentTintColor = ReaderTheme.canvas
        button.setButtonType(.momentaryPushIn)
        listenButton = button

        card.addSubview(dot)
        card.addSubview(status)
        card.addSubview(button)
        container.addSubview(scroll)
        container.addSubview(card)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            card.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            card.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            card.widthAnchor.constraint(equalToConstant: 460),
            card.heightAnchor.constraint(equalToConstant: 64),

            dot.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            status.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            status.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -14),
            status.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            button.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 96),
            button.heightAnchor.constraint(equalToConstant: 36),
        ])

        updateListenButton()
        return window
    }

    private func install(text: String) {
        isPDF = false
        pdfView?.isHidden = true
        textScroll?.isHidden = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        paragraph.paragraphSpacing = 14
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: ReaderTheme.readingFont(),
                .foregroundColor: ReaderTheme.textPrimary,
                .paragraphStyle: paragraph,
            ]
        )
        textView?.textStorage?.setAttributedString(attributed)
    }

    private static func readText(at url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    // MARK: - Listening

    @objc private func toggleListening() {
        switch engine.state {
        case .listening, .starting:
            engine.stop()
            isStarting = false
            setStatus("Paused", color: ReaderTheme.textSecondary)
            updateListenButton()
        default:
            startListening()
        }
    }

    private func startListening() {
        guard !tracker.sentences.isEmpty else {
            setStatus("Open a file first", color: ReaderTheme.textSecondary)
            return
        }
        guard !isStarting else { return }

        isStarting = true
        setStatus("Starting speech engine…", color: ReaderTheme.textSecondary)
        updateListenButton()

        Task { @MainActor in
            do {
                try await engine.start()
                readerStreaming = true
                setStatus("Listening — read aloud", color: ReaderTheme.readingStroke)
            } catch {
                setStatus(error.localizedDescription, color: ReaderTheme.danger)
            }
            isStarting = false
            updateListenButton()
        }
    }

    private func handleEngineState(_ state: SpeechEngineState) {
        if state != .listening {
            readerStreaming = false
        }
        switch state {
        case .idle:
            setStatus("Paused", color: ReaderTheme.textSecondary)
        case .starting(let message):
            setStatus(message, color: ReaderTheme.textSecondary)
        case .listening:
            setStatus("Listening — read aloud", color: ReaderTheme.readingStroke)
        case .failed(let message):
            setStatus(message, color: ReaderTheme.danger)
        }
        updateListenButton()
    }

    private func updateListenButton() {
        guard let listenButton else { return }
        let listening = engine.state == .listening
        var starting = isStarting
        if case .starting = engine.state { starting = true }
        listenButton.isEnabled = !starting && !tracker.sentences.isEmpty
        listenButton.title = starting ? "Starting…" : (listening ? "Stop" : "Listen")
        listenButton.alphaValue = listenButton.isEnabled ? 1 : 0.45
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
        statusLabel?.toolTip = text
        statusDot?.layer?.backgroundColor = color.cgColor
    }

    // MARK: - Highlights

    private func clearHighlights() {
        if isPDF {
            pdfHighlight?.currentRects = []
            pdfHighlight?.nextRects = []
            return
        }
        guard let layoutManager = textView?.layoutManager, highlighted else { return }
        removeHighlight(in: lastHighlighted, from: layoutManager)
        lastHighlighted = NSRange(location: 0, length: 0)
        highlighted = false
    }

    private func removeHighlight(in range: NSRange, from manager: NSLayoutManager) {
        guard range.length > 0 else { return }
        for key in [
            NSAttributedString.Key.backgroundColor,
            .foregroundColor,
            .underlineColor,
            .underlineStyle,
        ] {
            manager.removeTemporaryAttribute(key, forCharacterRange: range)
        }
    }

    private func renderHighlights() {
        if isPDF {
            renderPDFHighlights()
            return
        }
        guard let textView, let layoutManager = textView.layoutManager else { return }

        if highlighted {
            removeHighlight(in: lastHighlighted, from: layoutManager)
        }

        var union = NSRange(location: 0, length: 0)

        if let next = tracker.nextSentence {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: ReaderTheme.nextFill,
                forCharacterRange: next.range
            )
            union = union.union(next.range)
        }

        if let current = tracker.currentSentence {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: ReaderTheme.readingFill,
                forCharacterRange: current.range
            )
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: ReaderTheme.readingInk,
                forCharacterRange: current.range
            )
            layoutManager.addTemporaryAttribute(
                .underlineColor,
                value: ReaderTheme.readingStroke,
                forCharacterRange: current.range
            )
            layoutManager.addTemporaryAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: current.range
            )
            autoScroll(to: current.range)
            union = union.union(current.range)
        }

        lastHighlighted = union
        highlighted = union.length > 0
    }

    // MARK: - Auto-scroll

    /// The reader window scrolls natively: once the current sentence reaches
    /// the lower third, animate so it sits about a third from the top.
    private func autoScroll(to range: NSRange) {
        guard Date() >= manualScrollHoldUntil,
              let textView,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager,
              let clipView = textView.enclosingScrollView?.contentView else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect

        guard let pixels = AutoScrollPlanner.scrollDownPixels(
            sentenceTop: bounding.minY + origin.y - visible.minY,
            sentenceBottom: bounding.maxY + origin.y - visible.minY,
            viewportHeight: visible.height
        ), pixels > 0 else { return }

        let newOrigin = NSPoint(x: clipView.bounds.origin.x, y: clipView.bounds.origin.y + pixels)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(newOrigin)
        }
    }

    func userDidScroll() {
        manualScrollHoldUntil = Date().addingTimeInterval(1.5)
    }

    func moveCursor(by delta: Int) {
        tracker.moveCursor(by: delta)
    }

    /// PDF highlights come straight from PDFKit selections: exact line
    /// rectangles in the PDFView's own space, drawn by the document-glued
    /// highlight view.
    private func renderPDFHighlights() {
        guard let pdfView, let highlight = pdfHighlight else { return }

        let cursor = tracker.cursor
        var current: [CGRect] = []
        var next: [CGRect] = []

        if let cursor, pdfSentences.indices.contains(cursor) {
            current = pdfLineRects(for: pdfSentences[cursor])
        }
        if let nextIndex = cursor.map({ $0 + 1 }), pdfSentences.indices.contains(nextIndex) {
            next = pdfLineRects(for: pdfSentences[nextIndex])
        }

        highlight.currentRects = current
        highlight.nextRects = next

        if !current.isEmpty {
            autoScrollPDF(byRects: current)
        }
    }

    private func pdfLineRects(for sentence: PDFSentence) -> [CGRect] {
        guard let pdfView,
              let document = pdfView.document,
              let page = document.page(at: sentence.page),
              let selection = page.selection(for: sentence.localRange) else { return [] }
        // shortcut: PDFKit gives one union rect per selection, so a sentence
        // wrapped across lines highlights its bounding box — decompose per
        // line if that reads poorly over real documents.
        let pageRect = selection.bounds(for: page)
        return [pdfView.convert(pageRect, from: page)]
    }

    /// PDF auto-scroll: same thresholds as text, on the PDFView's own
    /// scroll view, animated.
    private func autoScrollPDF(byRects rects: [CGRect]) {
        guard Date() >= manualScrollHoldUntil,
              let pdfView,
              let clipView = pdfView.enclosingScrollView?.contentView else { return }

        let union = rects.dropFirst().reduce(rects[0], { CGRectUnion($0, $1) })
        let visible = pdfView.visibleRect

        guard let pixels = AutoScrollPlanner.scrollDownPixels(
            sentenceTop: union.minY - visible.minY,
            sentenceBottom: union.maxY - visible.minY,
            viewportHeight: visible.height
        ), pixels > 0 else { return }

        let newOrigin = NSPoint(x: clipView.bounds.origin.x, y: clipView.bounds.origin.y + pixels)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            clipView.animator().setBoundsOrigin(newOrigin)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        engine.stop()
        isStarting = false
        updateListenButton()
    }
}

private extension NSRange {
    func union(_ other: NSRange) -> NSRange {
        guard length > 0 else { return other }
        guard other.length > 0 else { return self }
        let start = min(location, other.location)
        let end = max(location + length, other.location + other.length)
        return NSRange(location: start, length: end - start)
    }
}

final class ReaderContainerView: NSView {
    weak var controller: ReaderController?

    /// Arrow keys advance and retreat the reading cursor so highlighting can
    /// be verified without a microphone (issue #3).
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125, 124: // down, right
            controller?.moveCursor(by: 1)
        case 126, 123: // up, left
            controller?.moveCursor(by: -1)
        default:
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        controller?.userDidScroll()
        super.scrollWheel(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        controller?.open(url: url)
        return true
    }

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options)
        return (objects as? [URL])?.first
    }
}
