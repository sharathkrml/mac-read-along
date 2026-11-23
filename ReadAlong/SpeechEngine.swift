import Foundation
import AVFoundation
import Darwin

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

    private var port = 8737
    /// The model name comes from a single setting; changing it restarts the
    /// engine (issue #4).
    private var model: String { AppSettings.standard.model }
    private var server: Process?
    private var socket: SpeechSocket?
    private let audio = AudioCapture()
    /// Which consumer opened the microphone stream, so onboarding can shut
    /// down its test without killing a live session.
    private(set) var streamOwner: ObjectIdentifier?

    /// Installs and starts the sidecar without touching the microphone —
    /// the onboarding engine step.
    func prepare() async throws {
        let binary = try await ensureRuntime()
        try await ensureServer(binary: binary)
    }

    func start(owner: ObjectIdentifier? = nil) async throws {
        if case .starting = state { return }
        if case .listening = state { return }
        state = .starting("Starting speech engine…")

        do {
            try await Self.ensureMicrophonePermission()
            try await prepare()
            let socket = try await connect()
            self.socket = socket

            try await startAudio(socket: socket)
            streamOwner = owner
            state = .listening
        } catch {
            audio.stop()
            socket?.close()
            socket = nil
            state = .failed(error.localizedDescription)
            Log.note("engine start failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// The setting changed: a live session restarts on the new model.
    func applyModelChange() {
        let wasListening = state == .listening
        let owner = streamOwner
        stop()
        // The old sidecar would answer health checks with the old model; kill
        // it so the next start boots the new one.
        if let server, server.isRunning {
            server.terminate()
        }
        server = nil
        guard wasListening else { return }
        Task { @MainActor in
            try? await self.start(owner: owner)
        }
    }

    /// The setting changed: reopen the microphone on the new device without
    /// interrupting the speech engine.
    func applyMicrophoneChange() {
        guard state == .listening, let socket else { return }
        audio.stop()
        state = .starting("Switching microphone…")
        Task { @MainActor in
            do {
                try await self.startAudio(socket: socket)
                self.state = .listening
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func startAudio(socket: SpeechSocket) async throws {
        try await audio.start(
            deviceID: AppSettings.standard.microphoneID,
            onPCM: { data in socket.sendPCM(data) },
            onFailure: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.fail(message)
                }
            },
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in
                    self?.emitLevel(level)
                }
            }
        )
    }

    typealias StateHandler = @MainActor (SpeechEngineState) -> Void
    typealias TranscriptHandler = @MainActor (TranscriptUpdate) -> Void
    typealias LevelHandler = @MainActor (Float) -> Void

    private var stateObservers: [(id: ObjectIdentifier, handler: StateHandler)] = []
    private var transcriptObservers: [(id: ObjectIdentifier, handler: TranscriptHandler)] = []
    private var levelObservers: [(id: ObjectIdentifier, handler: LevelHandler)] = []

    /// The engine is shared between the reader window and read-along
    /// sessions; both observe, and each ignores transcripts it did not start.
    func addObserver(
        id: ObjectIdentifier,
        onState: StateHandler? = nil,
        onTranscript: TranscriptHandler? = nil,
        onLevel: LevelHandler? = nil
    ) {
        if let onState {
            stateObservers.removeAll { $0.id == id }
            stateObservers.append((id, onState))
        }
        if let onTranscript {
            transcriptObservers.removeAll { $0.id == id }
            transcriptObservers.append((id, onTranscript))
        }
        if let onLevel {
            levelObservers.removeAll { $0.id == id }
            levelObservers.append((id, onLevel))
        }
    }

    func removeObserver(id: ObjectIdentifier) {
        stateObservers.removeAll { $0.id == id }
        transcriptObservers.removeAll { $0.id == id }
        levelObservers.removeAll { $0.id == id }
    }

    private func emitTranscript(_ update: TranscriptUpdate) {
        for observer in transcriptObservers { observer.handler(update) }
    }

    private func emitLevel(_ level: Float) {
        for observer in levelObservers { observer.handler(level) }
    }

    func stop() {
        audio.stop()
        socket?.close()
        socket = nil
        streamOwner = nil
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

    private static func freePort(startingAt start: Int) -> Int {
        for candidate in start...(start + 30) {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(candidate).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 { return candidate }
        }
        return start
    }

    private static func uvURL() -> URL? {        if let path = ProcessInfo.processInfo.environment["PATH"] {
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

    /// The sidecar outlives the app when the app is killed by a signal or
    /// crashes: it is reparented to launchd and keeps the model cached. Four
    /// of them piled up and exhausted memory on a 16 GB machine, taking
    /// WindowServer down with it. Reap every engine this install started
    /// except the one this app owns.
    private func reapOrphanedServers(binary: URL) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", binary.path + " serve"]
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        // The read above already returns once pgrep closes its output; waiting
        // for its exit can hang the main run loop, and its status is unused.
        let keep = server?.processIdentifier
        let stale = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0)) }
            .filter { $0 != keep }
        guard !stale.isEmpty else { return }

        Log.note("reaping \(stale.count) stale speech engine(s)")
        for pid in stale { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .milliseconds(500))
        for pid in stale where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }

    private func ensureServer(binary: URL) async throws {
        await reapOrphanedServers(binary: binary)
        if await isHealthy() { return }

        if let server, server.isRunning {
            server.terminate()
            // Never block the main actor on a sidecar that ignores SIGTERM;
            // give it two seconds, then take it down.
            for _ in 0..<20 {
                if !server.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if server.isRunning { kill(server.processIdentifier, SIGKILL) }
        }
        server = nil

        // A sidecar that survived the reap — or another process — may still
        // hold the port without answering health checks; take the next free one.
        port = Self.freePort(startingAt: port)
        Log.note("starting speech engine on port \(port)")

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
        streamOwner = nil
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
