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
    private var stateLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var activityBars: ActivityBars?
    private var documentTitleLabel: NSTextField?
    private var documentMetaLabel: NSTextField?
    private var progressValueLabel: NSTextField?
    private var progressMetaLabel: NSTextField?
    private var progressBar: ProgressBar?
    private var readingCard: NSView?
    private var sessionTimeLabel: NSTextField?
    private var sessionTimer: Timer?
    private var sessionStartedAt: Date?
    private var sessionElapsed: TimeInterval = 0
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
        updateDocumentCard(
            name: url.deletingPathExtension().lastPathComponent,
            kind: Self.documentKind(for: url),
            sentenceCount: tracker.sentences.count
        )
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
        updateDocumentCard(
            name: url.deletingPathExtension().lastPathComponent,
            kind: "PDF",
            sentenceCount: sentences.count
        )

        if sentences.isEmpty {
            updateDocumentMeta("PDF · NO SELECTABLE TEXT")
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
            view.backgroundColor = ReaderTheme.card

            highlight = PDFHighlightView(frame: .zero)
            highlight.autoresizingMask = [.width, .height]
            view.addSubview(highlight)

            guard let container = readingCard else { return }
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
        window?.ensureOnVisibleScreen()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Read Along"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ReaderTheme.canvas
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let container = ReaderContainerView()
        container.controller = self
        container.wantsLayer = true
        container.layer?.backgroundColor = ReaderTheme.canvas.cgColor
        container.registerForDraggedTypes([.fileURL])
        window.contentView = container

        let backdrop = BackdropView()
        container.addSubview(backdrop)

        // Document widget
        let documentCard = Widget.card()
        let documentIcon = Widget.iconTile(symbol: "text.alignleft")
        let documentMicro = Widget.microLabel("READING", color: ReaderTheme.amber)
        let documentTitle = Widget.titleLabel("No document", size: 20)
        let documentMeta = Widget.microLabel("OPEN A TEXT, MARKDOWN OR PDF FILE")
        documentTitleLabel = documentTitle
        documentMetaLabel = documentMeta
        documentCard.addSubview(documentIcon)
        documentCard.addSubview(documentMicro)
        documentCard.addSubview(documentTitle)
        documentCard.addSubview(documentMeta)

        // Progress widget
        let progressCard = Widget.card()
        let progressMicro = Widget.microLabel("PROGRESS")
        let progressValue = Widget.displayLabel("—", size: 30, weight: .light)
        progressValueLabel = progressValue
        let bar = ProgressBar()
        progressBar = bar
        let progressMeta = Widget.microLabel("NO DOCUMENT")
        progressMetaLabel = progressMeta
        progressCard.addSubview(progressMicro)
        progressCard.addSubview(progressValue)
        progressCard.addSubview(bar)
        progressCard.addSubview(progressMeta)

        // Reading surface
        let reading = NSView()
        reading.translatesAutoresizingMaskIntoConstraints = false
        reading.wantsLayer = true
        reading.layer?.backgroundColor = ReaderTheme.card.cgColor
        reading.layer?.cornerRadius = 30
        reading.layer?.borderWidth = 1
        reading.layer?.borderColor = ReaderTheme.hairline.cgColor
        reading.layer?.masksToBounds = true
        readingCard = reading

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        textScroll = scroll

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = ReaderTheme.textPrimary
        textView.font = ReaderTheme.readingFont(size: 20)
        textView.textContainerInset = NSSize(width: 56, height: 44)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        self.textView = textView
        reading.addSubview(scroll)

        // Session widget
        let control = Widget.card(radius: 28)
        let bars = ActivityBars()
        activityBars = bars
        let state = Widget.microLabel("PAUSED")
        stateLabel = state
        let detail = Widget.titleLabel("PHONON-2 · ENGLISH", size: 11, weight: .regular, color: ReaderTheme.textSecondary)
        detailLabel = detail
        let time = Widget.displayLabel("00:00", size: 28, weight: .light)
        sessionTimeLabel = time
        let timeMicro = Widget.microLabel("SESSION")
        let timeStack = NSStackView(views: [time, timeMicro])
        timeStack.translatesAutoresizingMaskIntoConstraints = false
        timeStack.orientation = .vertical
        timeStack.alignment = .centerX
        timeStack.spacing = 1

        let button = PillButton("Listen", kind: .primary)
        button.onPress = { [weak self] in self?.toggleListening() }
        listenButton = button

        control.addSubview(bars)
        control.addSubview(state)
        control.addSubview(detail)
        control.addSubview(timeStack)
        control.addSubview(button)

        let readingColumnWidth = scroll.widthAnchor.constraint(equalToConstant: 760)
        readingColumnWidth.priority = .defaultHigh

        container.addSubview(documentCard)
        container.addSubview(progressCard)
        container.addSubview(reading)
        container.addSubview(control)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            documentCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            documentCard.topAnchor.constraint(equalTo: container.topAnchor, constant: 52),
            documentCard.heightAnchor.constraint(equalToConstant: 100),
            documentCard.trailingAnchor.constraint(equalTo: progressCard.leadingAnchor, constant: -16),

            progressCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            progressCard.topAnchor.constraint(equalTo: documentCard.topAnchor),
            progressCard.widthAnchor.constraint(equalToConstant: 260),
            progressCard.heightAnchor.constraint(equalToConstant: 100),

            documentIcon.leadingAnchor.constraint(equalTo: documentCard.leadingAnchor, constant: 20),
            documentIcon.centerYAnchor.constraint(equalTo: documentCard.centerYAnchor),

            documentMicro.leadingAnchor.constraint(equalTo: documentIcon.trailingAnchor, constant: 16),
            documentMicro.topAnchor.constraint(equalTo: documentCard.topAnchor, constant: 20),
            documentMicro.trailingAnchor.constraint(lessThanOrEqualTo: documentCard.trailingAnchor, constant: -20),

            documentTitle.leadingAnchor.constraint(equalTo: documentMicro.leadingAnchor),
            documentTitle.topAnchor.constraint(equalTo: documentMicro.bottomAnchor, constant: 6),
            documentTitle.trailingAnchor.constraint(equalTo: documentCard.trailingAnchor, constant: -20),

            documentMeta.leadingAnchor.constraint(equalTo: documentMicro.leadingAnchor),
            documentMeta.topAnchor.constraint(equalTo: documentTitle.bottomAnchor, constant: 5),
            documentMeta.trailingAnchor.constraint(lessThanOrEqualTo: documentCard.trailingAnchor, constant: -20),

            progressMicro.leadingAnchor.constraint(equalTo: progressCard.leadingAnchor, constant: 20),
            progressMicro.topAnchor.constraint(equalTo: progressCard.topAnchor, constant: 16),

            progressValue.leadingAnchor.constraint(equalTo: progressMicro.leadingAnchor),
            progressValue.topAnchor.constraint(equalTo: progressMicro.bottomAnchor, constant: 2),

            progressMeta.leadingAnchor.constraint(equalTo: progressMicro.leadingAnchor),
            progressMeta.bottomAnchor.constraint(equalTo: progressCard.bottomAnchor, constant: -14),
            progressMeta.trailingAnchor.constraint(lessThanOrEqualTo: progressCard.trailingAnchor, constant: -16),

            bar.leadingAnchor.constraint(equalTo: progressMicro.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: progressCard.trailingAnchor, constant: -20),
            bar.bottomAnchor.constraint(equalTo: progressMeta.topAnchor, constant: -7),
            bar.heightAnchor.constraint(equalToConstant: 4),

            reading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            reading.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            reading.topAnchor.constraint(equalTo: documentCard.bottomAnchor, constant: 16),
            reading.bottomAnchor.constraint(equalTo: control.topAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: reading.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: reading.bottomAnchor),
            scroll.centerXAnchor.constraint(equalTo: reading.centerXAnchor),
            scroll.widthAnchor.constraint(lessThanOrEqualTo: reading.widthAnchor, constant: -64),
            readingColumnWidth,

            control.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            control.widthAnchor.constraint(equalToConstant: 560),
            control.heightAnchor.constraint(equalToConstant: 96),

            bars.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 22),
            bars.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            bars.widthAnchor.constraint(equalToConstant: 26),
            bars.heightAnchor.constraint(equalToConstant: 20),

            state.leadingAnchor.constraint(equalTo: bars.trailingAnchor, constant: 12),
            state.topAnchor.constraint(equalTo: control.topAnchor, constant: 24),
            state.trailingAnchor.constraint(lessThanOrEqualTo: timeStack.leadingAnchor, constant: -14),

            detail.leadingAnchor.constraint(equalTo: state.leadingAnchor),
            detail.topAnchor.constraint(equalTo: state.bottomAnchor, constant: 4),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: timeStack.leadingAnchor, constant: -14),

            timeStack.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            timeStack.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            timeStack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -16),

            button.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 116),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])

        updateListenButton()
        updateProgress()
        return window
    }

    private func updateDocumentCard(name: String, kind: String, sentenceCount: Int) {
        documentTitleLabel?.stringValue = name
        documentMetaLabel?.attributedStringValue = ReaderTheme.micro(
            "\(kind) · \(sentenceCount) \(sentenceCount == 1 ? "SENTENCE" : "SENTENCES")"
        )
    }

    private func updateProgress() {
        let total = tracker.sentences.count
        let current = tracker.cursor.map { $0 + 1 } ?? 0
        progressBar?.progress = total > 0 ? CGFloat(current) / CGFloat(total) : 0

        guard total > 0 else {
            progressValueLabel?.stringValue = "—"
            progressMetaLabel?.attributedStringValue = ReaderTheme.micro("NO DOCUMENT")
            return
        }

        let value = NSMutableAttributedString(
            string: current == 0 ? "—" : "\(current)",
            attributes: [
                .font: ReaderTheme.display(size: 30, weight: .light),
                .foregroundColor: ReaderTheme.textPrimary,
            ]
        )
        value.append(NSAttributedString(
            string: " / \(total)",
            attributes: [
                .font: ReaderTheme.display(size: 18, weight: .light),
                .foregroundColor: ReaderTheme.textSecondary,
            ]
        ))
        progressValueLabel?.attributedStringValue = value
        progressMetaLabel?.attributedStringValue = ReaderTheme.micro(
            current == 0 ? "PRESS LISTEN TO BEGIN" : "SENTENCE \(current) OF \(total)"
        )
    }

    private func resetSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionStartedAt = nil
        sessionElapsed = 0
        updateSessionClock()
    }

    private func startSessionTimer() {
        guard sessionStartedAt == nil else { return }
        sessionStartedAt = Date()
        sessionTimer?.invalidate()
        sessionTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(sessionTick),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        if let started = sessionStartedAt {
            sessionElapsed = Date().timeIntervalSince(started)
            sessionStartedAt = nil
        }
        updateSessionClock()
    }

    @objc private func sessionTick() {
        updateSessionClock()
    }

    private func updateSessionClock() {
        let elapsed = sessionStartedAt.map { Date().timeIntervalSince($0) } ?? sessionElapsed
        let total = max(0, Int(elapsed))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let text: String
        if hours > 0 {
            text = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            text = String(format: "%02d:%02d", minutes, seconds)
        }
        sessionTimeLabel?.stringValue = text
    }

    private func install(text: String) {
        isPDF = false
        pdfView?.isHidden = true
        textScroll?.isHidden = false

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 16
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: ReaderTheme.readingFont(size: 20),
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

    private static func documentKind(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return "MARKDOWN"
        case "pdf": return "PDF"
        case "txt", "text": return "TEXT"
        default: return "DOCUMENT"
        }
    }

    private func updateDocumentMeta(_ text: String) {
        documentMetaLabel?.attributedStringValue = ReaderTheme.micro(text)
    }

    // MARK: - Listening

    @objc private func toggleListening() {
        switch engine.state {
        case .listening, .starting:
            engine.stop()
            isStarting = false
            stopSessionTimer()
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
        resetSessionTimer()
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
            stopSessionTimer()
            setStatus("Paused", color: ReaderTheme.textSecondary)
        case .starting(let message):
            setStatus(message, color: ReaderTheme.textSecondary)
        case .listening:
            startSessionTimer()
            setStatus("Listening — read aloud", color: ReaderTheme.readingStroke)
        case .failed(let message):
            stopSessionTimer()
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
        let model = AppSettings.standard.model.uppercased()
        let state: String
        let detail: String

        if color == ReaderTheme.danger {
            state = "ENGINE ERROR"
            detail = text
        } else if engine.state == .listening {
            state = "LISTENING"
            detail = "\(model) · ENGLISH"
        } else if case .starting = engine.state {
            state = "STARTING"
            detail = text
        } else if text.contains("press Listen") {
            state = "READY"
            detail = text
        } else if text == "Open a file first" {
            state = "NO DOCUMENT"
            detail = "Open a text, Markdown or PDF file"
        } else {
            state = "PAUSED"
            detail = text == "Paused" ? "\(model) · ENGLISH" : text
        }

        stateLabel?.attributedStringValue = ReaderTheme.micro(state, color: color)
        detailLabel?.stringValue = detail
        detailLabel?.toolTip = detail
        activityBars?.tint = color
        activityBars?.isActive = engine.state == .listening
        sessionTimeLabel?.alphaValue = engine.state == .listening ? 1 : 0.65
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
        updateProgress()
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
        stopSessionTimer()
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
