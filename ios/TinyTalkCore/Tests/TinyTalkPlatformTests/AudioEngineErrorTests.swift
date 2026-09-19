import XCTest
@testable import TinyTalkPlatform

/// Issue #39's second on-device data point surfaced as
/// "could not start audio capture: The operation couldn't be completed.
/// (TinyTalkPlatform.AudioEngineError error 1.)" -- the wrapper enum had no
/// description of its own, so the underlying NSError (which for the two
/// hand-built throw sites carries a precise NSLocalizedDescriptionKey) was
/// invisible. AppModel formats its message from error.localizedDescription,
/// so that is the property these tests pin.
final class AudioEngineErrorTests: XCTestCase {
    private enum PlainSwiftError: Error { case boom }

    func testCaptureStartFailedSurfacesTheUnderlyingReasonInLocalizedDescription() {
        // Exactly what installCaptureTapAndStart()'s invalid-format guard throws.
        let underlying = NSError(domain: "RealAudioEngine", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "input hardware format not yet valid (<AVAudioFormat: 0 ch, 0 Hz>) -- route still settling",
        ])
        let text = AudioEngineError.captureStartFailed(underlying).localizedDescription
        XCTAssertTrue(text.contains("input hardware format not yet valid"), text)
        XCTAssertTrue(text.contains("route still settling"), text)
        XCTAssertTrue(text.contains("[RealAudioEngine 2]"), "should name the underlying error's domain and code: \(text)")
        XCTAssertFalse(text.contains("AudioEngineError error"), "must not fall back to the opaque NSError bridging text: \(text)")
    }

    func testCaptureStartFailedFromAnAVFoundationStyleErrorKeepsItsDomainAndCode() {
        // engine.start() failures arrive as generic NSErrors whose own
        // localizedDescription is the unhelpful "operation couldn't be
        // completed" form -- the code (-10868 is
        // kAudioUnitErr_FormatNotSupported) is the only real signal.
        let underlying = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
        let text = AudioEngineError.captureStartFailed(underlying).localizedDescription
        XCTAssertTrue(text.contains("com.apple.coreaudio.avfaudio"), text)
        XCTAssertTrue(text.contains("-10868"), text)
    }

    func testSessionConfigurationFailedIsDistinguishableFromCaptureStartFailed() {
        let underlying = NSError(domain: NSOSStatusErrorDomain, code: 561017449, userInfo: [
            NSLocalizedDescriptionKey: "Session activation failed",
        ])
        let text = AudioEngineError.sessionConfigurationFailed(underlying).localizedDescription
        XCTAssertTrue(text.lowercased().contains("audio session"), text)
        XCTAssertTrue(text.contains("Session activation failed"), text)
        XCTAssertTrue(text.contains("[NSOSStatusErrorDomain 561017449]"), text)
        XCTAssertNotEqual(
            text,
            AudioEngineError.captureStartFailed(underlying).localizedDescription,
            "the two cases must not read the same"
        )
    }

    func testAPlainSwiftUnderlyingErrorIsNotReportedTwice() {
        // A non-NSError-backed Swift error already bridges to text that
        // contains its own type name + case index -- appending the
        // domain/code a second time would just be noise.
        let text = AudioEngineError.captureStartFailed(PlainSwiftError.boom).localizedDescription
        XCTAssertEqual(text.components(separatedBy: "PlainSwiftError").count - 1, 1, text)
    }

    func testStringInterpolationOfTheErrorIsTheSameReadableText() {
        // startCapturing()'s retry loop logs "\(error)" -- that should read
        // the same as localizedDescription, not the raw enum-case dump.
        let underlying = NSError(domain: "RealAudioEngine", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "could not create converter from A to B",
        ])
        let error = AudioEngineError.captureStartFailed(underlying)
        XCTAssertEqual("\(error)", error.localizedDescription)
        XCTAssertTrue("\(error)".contains("could not create converter from A to B"))
    }
}
