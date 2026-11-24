import AVFoundation
import Foundation

enum MicrophoneError: LocalizedError {
    case notAuthorized
    case noInputDevice
    case noInputFormat
    case tapInstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone access is not authorized. Allow Read Along in System Settings → Privacy & Security → Microphone."
        case .noInputDevice:
            return "No microphone input device was found."
        case .noInputFormat:
            return "The microphone input has no usable audio format."
        case .tapInstallFailed(let message):
            return "Could not start microphone capture: \(message)"
        }
    }
}

/// Maps 16 kHz float32 PCM to a 0…1 level for the setup window's waveform.
enum AudioLevel {
    static func rms(_ data: Data) -> Float {
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Float.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for sample in samples {
                sum += sample * sample
            }
            return (sum / Float(samples.count)).squareRoot()
        }
    }

    /// RMS from 0…1 to 0…1 on a dBFS scale, so quiet speech still moves the bars.
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels + 55) / 55, 0), 1)
    }
}

/// What the microphone picker lists, and the device capture resolves to. A
/// saved device that is no longer connected falls back to the system default.
enum MicrophoneCatalog {
    /// One picker row: `id` is the device's unique ID, empty for the system
    /// default.
    struct Choice {
        let id: String
        let title: String
    }

    static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// Picker rows shared by the setup window and the floating card. The system-default
    /// row names the device it currently resolves to so the choice is visible
    /// without opening the menu.
    static func choices(preferredID: String) -> [Choice] {
        let connected = devices()
        let defaultName = AVCaptureDevice.default(for: .audio)?.localizedName
            ?? connected.first?.localizedName
        var choices = [Choice(
            id: "",
            title: defaultName.map { "System default · \($0)" } ?? "System default"
        )]
        choices += connected.map { Choice(id: $0.uniqueID, title: $0.localizedName) }
        if !preferredID.isEmpty, !choices.contains(where: { $0.id == preferredID }) {
            choices.append(Choice(id: preferredID, title: "Saved microphone (not connected)"))
        }
        return choices
    }

    static func resolve(preferredID: String) -> AVCaptureDevice? {
        if !preferredID.isEmpty,
           let saved = devices().first(where: { $0.uniqueID == preferredID }) {
            return saved
        }
        return AVCaptureDevice.default(for: .audio) ?? devices().first
    }
}

/// Captures the microphone as 16 kHz mono float32 PCM and hands each buffer to
/// the speech engine. Uses AVCaptureAudioDataOutput rather than AVAudioEngine
/// taps because installTap can throw an uncatchable ObjC exception when no
/// input is usable.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var failureReported = false
    private var pcmHandler: (@Sendable (Data) -> Void)?
    private var failureHandler: (@Sendable (String) -> Void)?
    private var levelHandler: (@Sendable (Float) -> Void)?
    private var lastLevelAt: TimeInterval = 0
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var runtimeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.sharathkrml.readalong.audio")

    var isRunning: Bool {
        lock.withLock { running }
    }

    func start(
        deviceID: String,
        onPCM: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onLevel: (@Sendable (Float) -> Void)? = nil
    ) async throws {
        guard !isRunning else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MicrophoneError.notAuthorized
            }
        default:
            throw MicrophoneError.notAuthorized
        }

        guard let device = MicrophoneCatalog.resolve(preferredID: deviceID) else {
            throw MicrophoneError.noInputDevice
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicrophoneError.tapInstallFailed(error.localizedDescription)
        }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()

        guard session.canAddInput(input) else {
            throw MicrophoneError.noInputFormat
        }
        session.addInput(input)

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]

        guard session.canAddOutput(output) else {
            throw MicrophoneError.noInputFormat
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        lock.withLock {
            pcmHandler = onPCM
            failureHandler = onFailure
            levelHandler = onLevel
            lastLevelAt = 0
            failureReported = false
            running = true
        }

        self.session = session
        self.output = output
        session.startRunning()

        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.reportFailure(error?.localizedDescription ?? "The microphone input stopped.")
        }
    }

    func stop() {
        let wasRunning = lock.withLock {
            let was = running
            running = false
            pcmHandler = nil
            failureHandler = nil
            levelHandler = nil
            return was
        }
        guard wasRunning else { return }

        if let runtimeObserver {
            NotificationCenter.default.removeObserver(runtimeObserver)
            self.runtimeObserver = nil
        }
        session?.stopRunning()
        session = nil
        output = nil
    }

    private func reportFailure(_ message: String) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard running, !failureReported else { return nil }
            failureReported = true
            return failureHandler
        }
        handler?(message)
    }

    /// Throttled to ~30 Hz on the capture queue; the waveform repaints per update.
    private func reportLevel(_ data: Data) {
        let handler: (@Sendable (Float) -> Void)? = lock.withLock {
            guard running, let levelHandler else { return nil }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastLevelAt >= 0.033 else { return nil }
            lastLevelAt = now
            return levelHandler
        }
        handler?(AudioLevel.normalized(rms: AudioLevel.rms(data)))
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let handler = lock.withLock { running ? pcmHandler : nil }
        guard let handler else { return }

        guard let dataBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: nil,
            dataPointerOut: &pointer
        )
        guard status == noErr, let pointer, length > 0 else { return }
        let data = Data(bytes: pointer, count: length)
        handler(data)
        reportLevel(data)
    }
}
