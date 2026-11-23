import Darwin
import XCTest
@testable import ReadAlong

final class SpeechEngineLaunchTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReadAlongLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The sidecar must boot through the cache-capped shim; an uncapped MLX
    /// cache grew a single server to ~11 GB while streaming.
    func testManagedVenvBootsPythonWithACacheCappedBootstrap() throws {
        let venv = root.appendingPathComponent("venv", isDirectory: true)
        let bin = venv.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: venv.appendingPathComponent("pyvenv.cfg"))
        let python = bin.appendingPathComponent("python")
        try Data().write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let fermion = bin.appendingPathComponent("fermion")
        try Data().write(to: fermion)

        let launch = SpeechEngine.serverLaunch(binary: fermion, model: "phonon-2", port: 8737)

        XCTAssertEqual(launch.executable, python)
        XCTAssertEqual(launch.arguments.first, "-c")
        XCTAssertTrue(launch.arguments[1].contains("set_cache_limit"))
        XCTAssertEqual(Array(launch.arguments.dropFirst(2)), ["serve", "phonon-2", "--port", "8737"])
    }

    func testPlainBinaryFallsBackToServeArguments() throws {
        let fermion = root.appendingPathComponent("fermion")
        try Data().write(to: fermion)

        let launch = SpeechEngine.serverLaunch(binary: fermion, model: "phonon-2", port: 8737)

        XCTAssertEqual(launch.executable, fermion)
        XCTAssertEqual(launch.arguments, ["serve", "phonon-2", "--port", "8737"])
    }

    /// The memory watchdog depends on this call; if it silently returned nil
    /// the guard would never fire. Also covers the API that once crashed.
    func testReadsThePhysicalFootprintOfALiveProcess() {
        let footprint = SpeechEngine.physicalFootprint(of: getpid())
        XCTAssertNotNil(footprint)
        XCTAssertGreaterThan(footprint ?? 0, 0)
    }
}
