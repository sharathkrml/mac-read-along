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
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var runtimeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.sharathkrml.readalong.audio")

    var isRunning: Bool {
        lock.withLock { running }
    }

    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
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

        guard let device = Self.inputDevice() else {
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

    private static func inputDevice() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(for: .audio) {
            return device
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices.first
    }

    private func reportFailure(_ message: String) {
        let handler: (@Sendable (String) -> Void)? = lock.withLock {
            guard running, !failureReported else { return nil }
            failureReported = true
            return failureHandler
        }
        handler?(message)
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
        handler(Data(bytes: pointer, count: length))
    }
}
