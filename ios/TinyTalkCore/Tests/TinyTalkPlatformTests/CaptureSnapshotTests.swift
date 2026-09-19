import XCTest
@testable import TinyTalkPlatform

/// The snapshot line is what the household reads off the Settings debug log
/// to tell issue #39's hypotheses apart, so the tokens the "how to read the
/// log" guide points at have to actually be there, spelled that way.
final class CaptureSnapshotTests: XCTestCase {
    private func makeSnapshot(
        label: String = "startCapturing: begin",
        engineId: Int = 3,
        engineRunning: Bool = false,
        engineRunningBefore: Bool? = nil,
        tapInstalled: Bool = false,
        inputSampleRate: Double = 48000,
        inputChannelCount: Int = 1,
        inputPorts: [String] = ["MicrophoneBuiltIn"],
        liveEngines: Int = 1,
        otherEngines: [CaptureSnapshot.OtherEngine] = [],
        counts: CaptureDiagnostics.Counts = .init()
    ) -> CaptureSnapshot {
        CaptureSnapshot(
            label: label,
            engineId: engineId,
            engineRunning: engineRunning,
            engineRunningBefore: engineRunningBefore,
            tapInstalled: tapInstalled,
            inputSampleRate: inputSampleRate,
            inputChannelCount: inputChannelCount,
            session: .init(
                category: "AVAudioSessionCategoryPlayAndRecord",
                mode: "AVAudioSessionModeVoiceChat",
                otherAudioPlaying: false,
                silenceSecondaryAudioHint: false,
                inputAvailable: true,
                inputPorts: inputPorts,
                sampleRate: 48000
            ),
            liveEngines: liveEngines,
            otherEngines: otherEngines,
            counts: counts
        )
    }

    func testLineCarriesTheInstanceIdLabelAndEveryStateToken() {
        let line = makeSnapshot(engineRunning: true, tapInstalled: true, liveEngines: 2).formatted
        XCTAssertTrue(line.hasPrefix("RealAudioEngine#3 startCapturing: begin"), line)
        for token in [
            "engine.isRunning=true", "tap=true", "input=48000Hz/1ch", "live=2",
            "session=PlayAndRecord/VoiceChat", "otherAudio=false", "silenceHint=false",
            "inputAvailable=true", "route.in=[MicrophoneBuiltIn]",
            "buffers=0", "chunks=0", "peak=0",
        ] {
            XCTAssertTrue(line.contains(token), "missing \(token) in: \(line)")
        }
    }

    func testEngineRunningShowsBeforeToAfterWhenTheBeforeValueIsKnown() {
        // startCapturing()/stopCapturing() record isRunning on the way in.
        let started = makeSnapshot(engineRunning: true, engineRunningBefore: false).formatted
        XCTAssertTrue(started.contains("engine.isRunning=false->true"), started)
        let stopped = makeSnapshot(engineRunning: false, engineRunningBefore: true).formatted
        XCTAssertTrue(stopped.contains("engine.isRunning=true->false"), stopped)
    }

    func testAnInvalidInputFormatIsFlaggedLoudly() {
        // A 0 Hz / 0-channel input node is the classic hardware-contention
        // symptom -- and the same condition installCaptureTapAndStart()
        // refuses to install a tap against.
        XCTAssertTrue(makeSnapshot(inputSampleRate: 0, inputChannelCount: 0).formatted.contains("input=0Hz/0ch(INVALID)"))
        XCTAssertTrue(makeSnapshot(inputSampleRate: 48000, inputChannelCount: 0).formatted.contains("input=48000Hz/0ch(INVALID)"))
        XCTAssertTrue(makeSnapshot(inputSampleRate: 0, inputChannelCount: 1).formatted.contains("input=0Hz/1ch(INVALID)"))
        XCTAssertFalse(makeSnapshot().formatted.contains("INVALID"))
    }

    func testNoOtherEnginesReadsAsNone() {
        XCTAssertTrue(makeSnapshot().formatted.contains("others=none"))
    }

    func testOtherLiveEnginesAreListedWithTheirStopAndRunningState() {
        // The smoking gun for hypothesis 1: an OLD engine that was told to
        // stop but reports isRunning == true again (e.g. restarted by a late
        // play()) while the new one is starting.
        let line = makeSnapshot(
            liveEngines: 3,
            otherEngines: [
                .init(id: 1, stopCalled: true, engineRunning: false),
                .init(id: 2, stopCalled: true, engineRunning: true),
            ]
        ).formatted
        XCTAssertTrue(
            line.contains("others=[#1 stopCalled=true engine.isRunning=false, #2 stopCalled=true engine.isRunning=true]"),
            line
        )
    }

    func testAnEmptyInputRouteIsFlaggedNotJustBlank() {
        XCTAssertTrue(makeSnapshot(inputPorts: []).formatted.contains("route.in=[NONE]"))
        XCTAssertTrue(makeSnapshot(inputPorts: ["BluetoothHFP", "MicrophoneBuiltIn"]).formatted.contains("route.in=[BluetoothHFP,MicrophoneBuiltIn]"))
    }

    func testCountersAppearSoZeroBuffersIsDistinguishableFromDroppedOrSilentBuffers() {
        let line = makeSnapshot(counts: .init(buffersReceived: 42, chunksDelivered: 40, peakAmplitude: 1234)).formatted
        XCTAssertTrue(line.contains("buffers=42 chunks=40 peak=1234"), line)
    }

    func testTheWholeLineIsASingleLine() {
        // Rendered as one entry in the 50-line on-screen debug log.
        XCTAssertFalse(makeSnapshot(otherEngines: [.init(id: 1, stopCalled: true, engineRunning: true)]).formatted.contains("\n"))
    }
}
