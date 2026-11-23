import Foundation
import AVFoundation

enum SpeechEngineState: Equatable {
    case idle
    case starting(String)
    case listening
    case failed(String)
}

struct TranscriptUpdate: Equatable {
    let text: String
    let isFinal: Bool
}

enum SpeechEngineError: LocalizedError {
    case fermionMissing
    case serverExited(String)
    case serverTimeout
    case installFailed(Int)
    case uvMissing

    var errorDescription: String? {
        switch self {
        case .fermionMissing:
            return "The Phonon speech engine could not be installed at ~/Library/Application Support/ReadAlong/venv."
        case .serverExited(let detail):
            return "The speech engine stopped during startup. \(detail)"
        case .serverTimeout:
            return "The speech engine did not become ready in time."
        case .installFailed(let status):
            return "Installing the speech engine failed (exit status \(status))."
        case .uvMissing:
            return "The uv tool is required to install the speech engine. Install it with `brew install uv`."
        }
    }
}

/// Owns the local `fermion serve` sidecar, the microphone, and the live
/// WebSocket stream. One stream at a time, matching the server's limit.
@MainActor
final class SpeechEngine {
    private(set) var state: SpeechEngineState = .idle {
        didSet {
            if state != oldValue {
                for observer in stateObservers { observer.handler(state) }
            }
        }
    }

    private let port = 8737
    /// The model name comes from a single setting; changing it restarts the
    /// engine (issue #4).
    private var model: String { AppSettings.standard.model }
    private var server: Process?
    private var socket: SpeechSocket?
    private let audio = AudioCapture()

    /// Installs and starts the sidecar without touching the microphone —
    /// the onboarding engine step.
    func prepare() async throws {
        let binary = try await ensureRuntime()
        try await ensureServer(binary: binary)
    }

    func start() async throws {
        if case .starting = state { return }
        if case .listening = state { return }
        state = .starting("Starting speech engine…")

        do {
            try await Self.ensureMicrophonePermission()
            try await prepare()
            let socket = try await connect()
            self.socket = socket

            try await audio.start(
                onPCM: { data in socket.sendPCM(data) },
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.fail(message)
                    }
                }
            )
            state = .listening
        } catch {
            audio.stop()
            socket?.close()
            socket = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// The setting changed: a live session restarts on the new model.
    func applyModelChange() {
        let wasListening = state == .listening
        stop()
        // The old sidecar would answer health checks with the old model; kill
        // it so the next start boots the new one.
        if let server, server.isRunning {
            server.terminate()
        }
        server = nil
        guard wasListening else { return }
        Task { @MainActor in
            try? await self.start()
        }
    }

    typealias StateHandler = @MainActor (SpeechEngineState) -> Void
    typealias TranscriptHandler = @MainActor (TranscriptUpdate) -> Void

    private var stateObservers: [(id: ObjectIdentifier, handler: StateHandler)] = []
    private var transcriptObservers: [(id: ObjectIdentifier, handler: TranscriptHandler)] = []

    /// The engine is shared between the reader window and read-along
    /// sessions; both observe, and each ignores transcripts it did not start.
    func addObserver(
        id: ObjectIdentifier,
        onState: StateHandler? = nil,
        onTranscript: TranscriptHandler? = nil
    ) {
        if let onState {
            stateObservers.removeAll { $0.id == id }
            stateObservers.append((id, onState))
        }
        if let onTranscript {
            transcriptObservers.removeAll { $0.id == id }
            transcriptObservers.append((id, onTranscript))
        }
    }

    func removeObserver(id: ObjectIdentifier) {
        stateObservers.removeAll { $0.id == id }
        transcriptObservers.removeAll { $0.id == id }
    }

    private func emitTranscript(_ update: TranscriptUpdate) {
        for observer in transcriptObservers { observer.handler(update) }
    }

    func stop() {
        audio.stop()
        socket?.close()
        socket = nil
        if case .failed = state { return }
        state = .idle
    }

    func shutdown() {
        stop()
        if let server, server.isRunning {
            server.terminate()
        }
        server = nil
    }

    // MARK: - Runtime

    private func ensureRuntime() async throws -> URL {
        if let existing = Self.fermionURL() {
            return existing
        }

        guard let uv = Self.uvURL() else {
            throw SpeechEngineError.uvMissing
        }

        setStarting("Setting up the speech engine…")

        let manager = FileManager.default
        let appSupport = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadAlong", isDirectory: true)
        try manager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let venv = appSupport.appendingPathComponent("venv", isDirectory: true)
        try await run(uv, ["venv", "--python", "3.12", venv.path])

        let python = venv.appendingPathComponent("bin/python")
        try await run(uv, ["pip", "install", "--python", python.path, "fermion-research[mlx]"])

        let fermion = venv.appendingPathComponent("bin/fermion")
        guard manager.isExecutableFile(atPath: fermion.path) else {
            throw SpeechEngineError.fermionMissing
        }
        return fermion
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Log.server.notice("\(text, privacy: .public)")
            }
        }

        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        if process.terminationStatus != 0 {
            throw SpeechEngineError.installFailed(Int(process.terminationStatus))
        }
    }

    private func setStarting(_ message: String) {
        let next = SpeechEngineState.starting(String(message.prefix(120)))
        if state != next {
            state = next
        }
    }

    private static func uvURL() -> URL? {
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for component in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent("uv")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let known = [
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv").path,
        ]
        return known.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static func ensureMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MicrophoneError.notAuthorized
            }
        default:
            throw MicrophoneError.notAuthorized
        }
    }

    private func ensureServer(binary: URL) async throws {
        if await isHealthy() { return }

        if let server, server.isRunning {
            server.terminate()
            server.waitUntilExit()
        }
        server = nil

        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", model, "--port", String(port)]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        let statusBox = StatusBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Log.server.notice("\(text, privacy: .public)")
            guard let line = text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            else { return }
            statusBox.set(line)
        }

        do {
            try process.run()
        } catch {
            throw SpeechEngineError.fermionMissing
        }
        server = process

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            if await isHealthy() { return }
            if !process.isRunning {
                throw SpeechEngineError.serverExited("Exit status \(process.terminationStatus).")
            }
            if let line = statusBox.value {
                setStarting(line)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw SpeechEngineError.serverTimeout
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private static func fermionURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["READALONG_FERMION"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let managed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ReadAlong/venv/bin/fermion")
        if FileManager.default.isExecutableFile(atPath: managed.path) {
            return managed
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for component in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(component)).appendingPathComponent("fermion")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Socket

    private func connect() async throws -> SpeechSocket {
        guard let url = URL(string: "ws://127.0.0.1:\(port)/v1/audio/stream") else {
            throw SpeechEngineError.serverExited("Invalid stream URL.")
        }

        let socket = SpeechSocket(
            url: url,
            onText: { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.handleMessage(text)
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.fail(message)
                }
            }
        )
        socket.connect()
        try await socket.sendConfiguration()
        return socket
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        switch type {
        case "partial":
            if let body = object["text"] as? String, !body.isEmpty {
                emitTranscript(TranscriptUpdate(text: body, isFinal: false))
            }
        case "final":
            if let body = object["text"] as? String, !body.isEmpty {
                emitTranscript(TranscriptUpdate(text: body, isFinal: true))
            }
        case "error":
            fail(object["message"] as? String ?? "The speech stream stopped.")
        default:
            break
        }
    }

    private func fail(_ message: String) {
        audio.stop()
        socket?.close()
        socket = nil
        state = .failed(message)
    }
}

/// Thread-safe slot for the sidecar's latest stderr line, used as a status.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func set(_ value: String) {
        lock.withLock { text = value }
    }

    var value: String? {
        let current = lock.withLock { text }
        return current.isEmpty ? nil : current
    }
}

/// Thin thread-safe wrapper around the WebSocket: audio arrives on the capture
/// queue while the receive loop runs on URLSession's queue.
final class SpeechSocket: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let onText: @Sendable (String) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let lock = NSLock()
    private var closed = false

    init(url: URL, onText: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.task = URLSession.shared.webSocketTask(with: url)
        self.onText = onText
        self.onFailure = onFailure
    }

    func connect() {
        task.resume()
        receiveNext()
    }

    func sendConfiguration() async throws {
        try await task.send(.string(#"{"sample_rate":16000,"format":"pcm_f32le"}"#))
    }

    func sendPCM(_ data: Data) {
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }
        task.send(.data(data)) { _ in }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        task.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let isClosed = self.closed
            self.lock.unlock()
            guard !isClosed else { return }

            switch result {
            case .success(let message):
                if case .string(let text) = message {
                    self.onText(text)
                }
                self.receiveNext()
            case .failure(let error):
                self.onFailure(error.localizedDescription)
            }
        }
    }
}
