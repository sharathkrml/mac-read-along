import XCTest
@testable import ReadAlong

final class AudioLevelTests: XCTestCase {
    func testRMSOfFloatSamples() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(AudioLevel.rms(data), 0.5, accuracy: 0.0001)
    }

    func testSilenceHasNoLevel() {
        XCTAssertEqual(AudioLevel.normalized(rms: 0), 0)
    }

    func testFullScaleIsOne() {
        XCTAssertEqual(AudioLevel.normalized(rms: 1), 1)
    }

    func testQuietSpeechSitsInTheMiddleOfTheScale() {
        // -30 dBFS is quiet speech; it should still move the bars visibly.
        let level = AudioLevel.normalized(rms: 0.03)
        XCTAssertGreaterThan(level, 0.35)
        XCTAssertLessThan(level, 0.6)
    }
}
