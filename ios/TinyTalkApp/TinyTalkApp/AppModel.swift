import AVFoundation
import SwiftUI
import TinyTalkCore
import TinyTalkPlatform
import UIKit

/// Which top-level screen is currently shown. Navigation lives here (not in
/// a SwiftUI NavigationStack) because several transitions have side effects
/// on the session itself (finishing onboarding requests mic permission,
/// starting a story connects, going home disconnects) -- keeping screen
/// alongside that state avoids splitting one decision across two owners.
enum AppScreen: Equatable {
    case onboarding
    case landing
    case creating
    case settings
    case library
    case reading
    case theEnd
}

/// One line of the on-screen story-so-far, built entirely client-side from
/// AppModel's own polled lastTranscript/lastReply -- SessionCoordinator only
/// ever exposes the CURRENT turn's latest transcript/reply (see its doc
/// comments), not a running history, so there is nothing server-side to
/// read this from. Deliberately bounded by the same disconnect/new-story
/// resets that already clear debugLog, rather than persisted anywhere --
/// this is a presentation convenience, not a second copy of the story
/// (server/tinytalk/story_store.py's turn list remains the one real record).
struct StoryTurn: Identifiable, Equatable {
    enum Speaker: Equatable { case child, elsie }

    let id = UUID()
    let speaker: Speaker
    let text: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var serverAddress: String
    @Published var awayFromHomeEnabled: Bool
    @Published var screen: AppScreen
    @Published var state: SessionState = .idle
    @Published var lastTranscript: String = ""
    @Published var lastReply: String = ""
    @Published var lastErrorMessage: String?
    @Published var latencyHistory: [InterruptLatency] = []
    @Published var isConnected = false
    @Published var isMicMuted = false
    @Published var objectRecognitionHint: String?
    @Published var turns: [StoryTurn] = []
    /// Saved-story fixtures for the Library screen -- populated by
    /// Settings' preview buttons or TheEndView's "Read it now" until the
    /// real list_stories() wire call is wired up (see MockStories.swift).
    @Published var libraryStories: [SavedStorySummary] = []
    /// The story currently shown by TheEndView/ReadingView -- populated by
    /// whichever screen navigates to them (a Library card tap, or a
    /// Settings preview button).
    @Published var selectedStory: SavedStoryDetail?
    /// The turn_id most recently sent on speechStart/interrupt/resume --
    /// debug UI, added while diagnosing the disconnect/reconnect turn-id
    /// mismatch bug, to let you SEE at a glance whether a reconnect
    /// resumed the right turn instead of silently discarding everything.
    @Published var currentTurnId: Int = 0
    /// SessionCoordinator.debugLog merged with RealAudioEngine's own
    /// onDebugEvent hook -- see both those doc comments. Kept as two
    /// separate arrays (below) and re-merged on every update, since the two
    /// sources update independently (coordinatorDebugLog on each 100ms poll
    /// tick, audioDebugLog the instant RealAudioEngine's hook fires) and
    /// RealAudioEngine has no reference back to the coordinator to append
    /// into its debugLog directly.
    @Published var debugLog: [String] = []
    private var coordinatorDebugLog: [String] = []
    private var audioDebugLog: [String] = []

    private var coordinator: SessionCoordinator?
    private var audioEngine: RealAudioEngine?
    private let objectRecognizer = VisionObjectRecognizer()
    private let pendingDemoStore = PendingDemoStore()
    private var runLoop: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Which turn_id's transcript/reply has already been appended to
    /// `turns` -- without this, every 100ms poll tick would re-append the
    /// same still-current turn's text again. Not a perfect boundary (a poll
    /// tick can in principle land just as currentTurnId advances to a new
    /// turn before this turn's own reply was polled), but this is a
    /// presentation nicety, not the source of truth -- see StoryTurn's doc
    /// comment.
    private var lastAppendedTranscriptTurnId: Int?
    private var lastAppendedReplyTurnId: Int?
    /// Ordered pipe from the audio tap's real-time callback into the
    /// coordinator actor. Kept as a stream (not a per-buffer `Task { await
    /// coordinator.captureAudio(pcm) }`) because separate unstructured
    /// Tasks have no FIFO guarantee when calling into an actor -- under
    /// congestion (e.g. captureAudio() awaiting a slow connection.send()),
    /// buffers could arrive at the actor out of order, corrupting both the
    /// uploaded audio stream and the VAD's stateful resampler/LSTM state
    /// chain, which assumes strictly sequential audio. continuation.yield()
    /// is cheap and non-blocking from the tap's real-time thread, and a
    /// single long-lived consumer task drains the stream strictly in order.
    private var micStreamContinuation: AsyncStream<Data>.Continuation?
    private var micConsumerTask: Task<Void, Never>?
    /// True only when this app itself disconnected because it was
    /// backgrounded WHILE actually connected -- see
    /// handleAppBackgrounded()/handleAppForegrounded(). Distinguishes
    /// "reconnect automatically, the user didn't ask for this" from a
    /// disconnect the user chose themselves (tapped Disconnect) or one
    /// the server side already caused (startPollingState()'s `closed`
    /// handling) -- neither of those should be silently overridden by
    /// auto-reconnecting the next time the app becomes active again.
    private var shouldReconnectOnForeground = false
    /// Whichever turn_id should be resumed on the NEXT connect() attempt,
    /// or nil if there is nothing to resume. Two independent writers:
    /// handleAppBackgrounded() sets it proactively (reads live coordinator
    /// state before an intentional disconnect it's about to cause), and
    /// startPollingState()'s poll loop sets it reactively, from
    /// coordinator.resumableTurnIdAtDisconnect, whenever it notices the
    /// connection died on its own (a network drop, a server hiccup --
    /// what an ordinary "the app is open and waiting, then it randomly
    /// disconnects" looks like). Both feed the same value into the same
    /// place: connectResumingIfPending() reads and clears it, exactly like
    /// handleAppForegrounded() already does for the backgrounding case.
    /// Root-cause fix: previously only the backgrounding path ever set
    /// this, so the manual "Connect" button -- used after every OTHER kind
    /// of disconnect -- always resumed nothing, silently discarding
    /// whatever the server replayed (turn_id 0 from a fresh coordinator
    /// never matches the server's real turn_id) and landing back at
    /// .idle with no ditty and no reply, exactly as reported.
    /// disconnectUserInitiated() explicitly clears this -- a disconnect
    /// the user chose themselves must never be silently overridden by an
    /// auto-resume on their next manual reconnect.
    private var pendingResumeTurnId: Int?

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
        awayFromHomeEnabled = UserDefaults.standard.bool(forKey: "awayFromHomeEnabled")
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        screen = hasOnboarded ? .landing : .onboarding
    }

    /// The Settings toggle calls this (not $awayFromHomeEnabled directly)
    /// so the choice survives an app relaunch, matching serverAddress's
    /// own persistence.
    func setAwayFromHomeEnabled(_ enabled: Bool) {
        awayFromHomeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "awayFromHomeEnabled")
    }

    /// What Onboarding's primary button calls -- requests mic permission up
    /// front (rather than waiting for the first connect()) so the child
    /// sees the system prompt right after the screen that explains why it's
    /// needed, matching the design's own "Can I hear you?" copy. connect()
    /// re-checks permission regardless, so a denial here isn't fatal -- it
    /// just means connect() will surface its own clear error later, exactly
    /// as it already does today.
    func finishOnboarding() async {
        _ = await RealAudioEngine.requestMicrophonePermission()
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        screen = .landing
    }

    /// What Landing's "Create a Story" button (and the menu's "New Story"
    /// entry, for a first connect from a cold app launch) calls. Reuses
    /// connectResumingIfPending() as-is so backgrounding/resume behavior is
    /// identical regardless of which screen initiated the connect.
    func startStory() async {
        screen = .creating
        await connectResumingIfPending()
    }

    /// What the story screen's "Home" menu item calls -- a deliberate
    /// disconnect, matching disconnectUserInitiated()'s existing "never
    /// auto-resume this" semantics.
    func goHome() {
        disconnectUserInitiated()
        screen = .landing
    }

    func connect(resumingTurnId: Int? = nil) async {
        UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
        guard let url = URL(string: serverAddress) else {
            lastErrorMessage = "invalid server address"
            return
        }

        guard await RealAudioEngine.requestMicrophonePermission() else {
            lastErrorMessage = "microphone access denied. Check Settings > Privacy > Microphone > TinyTalkApp."
            return
        }

        let connection = WebSocketServerConnection(url: url)
        guard let audio = try? RealAudioEngine() else {
            lastErrorMessage = "failed to configure audio session"
            return
        }
        audioEngine = audio
        // Merge RealAudioEngine's own diagnostic lines into the same
        // on-screen debug log as the coordinator's -- see debugLog's doc
        // comment. Hops onto the main actor since appendAudioDebugEvent
        // mutates @Published state; the hook itself can fire from a
        // notification callback or an AVAudioEngine completion handler, not
        // necessarily the main thread.
        audio.onDebugEvent = { [weak self] line in
            Task { @MainActor in
                self?.appendAudioDebugEvent(line)
            }
        }

        guard let vadModelPath = Bundle.main.path(forResource: "silero_vad", ofType: "onnx"),
              let vad = try? SileroVoiceActivityDetector(modelPath: vadModelPath) else {
            lastErrorMessage = "failed to load VAD model"
            return
        }

        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad, waitingDittyAudio: WaitingDitty.audio)
        self.coordinator = coordinator
        // Must happen BEFORE start() below: resume() sets up turnTask/
        // currentTurnId synchronously so that once consumeServerEvents()
        // (started by start()) begins reading connection.events(), nothing
        // the server replays for this turn_id can be discarded as stale for
        // arriving before anything was listening for it. Deliberately does
        // NOT start the waiting ditty yet -- see the startResumedWaitingDitty()
        // call further down, and resume()'s own doc comment, for why that
        // has to wait until after mic capture has configured the engine.
        if let resumingTurnId {
            print("AppModel: resuming turn_id=\(resumingTurnId)")
            await coordinator.resume(turnId: resumingTurnId)
        } else {
            print("AppModel: fresh connect, no turn to resume")
        }
        runLoop = Task { await coordinator.start() }

        let (micStream, micContinuation) = AsyncStream<Data>.makeStream()
        micStreamContinuation = micContinuation
        micConsumerTask = Task { [weak self] in
            for await pcm in micStream {
                await self?.coordinator?.captureAudio(pcm)
            }
        }

        do {
            // micContinuation is a value type (AsyncStream.Continuation is a
            // struct), so capturing it here does not retain `self` or the
            // coordinator -- no weak-capture is needed or possible.
            try await audio.startCapturing { pcm in
                micContinuation.yield(pcm)
            }
        } catch {
            // The most common real cause here is the user denying the
            // microphone permission prompt -- AVAudioEngine's start()
            // fails rather than throwing a dedicated "permission denied"
            // error, so this generic message is what's actually
            // achievable without over-guessing at AVFoundation's exact
            // error taxonomy. The design spec requires this be surfaced
            // clearly rather than silently swallowed.
            lastErrorMessage = "could not start audio capture: \(error.localizedDescription). Check Settings > Privacy > Microphone."
            disconnect()
            return
        }

        // Only now -- after startCapturing() has configured
        // RealAudioEngine's input side -- is it safe to start the waiting
        // ditty (the first thing that calls play()/engine.start()).
        // Confirmed on real hardware: calling play() any earlier than this
        // reliably fails with an input/output sample-rate mismatch inside
        // CoreAudio's voice-processing unit, every single retry attempt,
        // regardless of how long play()'s own retry loop waits.
        if resumingTurnId != nil {
            await coordinator.startResumedWaitingDitty()
        }

        isConnected = true
        let pending = pendingDemoStore.loadAll()
        if !pending.isEmpty {
            do {
                try await coordinator.syncDemoStories(pending)
                pendingDemoStore.clear()
            } catch {
                // Best effort, same reasoning as sendObjectSeen -- left
                // for the next successful reconnect to retry; nothing
                // is lost, since PendingDemoStore was not cleared.
                print("AppModel: failed to sync demo stories: \(error)")
            }
        }
        startPollingState()
    }

    /// Away-from-home counterpart to connect() -- builds a DemoConnection
    /// against Groq instead of a WebSocketServerConnection against the
    /// Mac. See the design spec's disclosed simplification: unlike the
    /// real server, there is no persistent session to resume if the app
    /// is backgrounded mid-reply -- that reply is simply lost, not
    /// replayed.
    func connectAwayFromHome() async {
        guard let groqKey = KeychainStore.get("groqApiKey"), !groqKey.isEmpty else {
            lastErrorMessage = "no Groq API key saved -- add one in Settings, under Away From Home."
            return
        }
        guard await RealAudioEngine.requestMicrophonePermission() else {
            lastErrorMessage = "microphone access denied. Check Settings > Privacy > Microphone > TinyTalkApp."
            return
        }

        let animalFactsKey = KeychainStore.get("animalFactsApiKey")
        let connection = DemoConnection(
            chatClient: GroqChatClient(apiKey: groqKey),
            sttClient: GroqWhisperClient(apiKey: groqKey),
            ttsClient: AVSpeechTts(),
            animalFactTracker: AnimalFactTracker(fetcher: AnimalFactsAPIClient(apiKey: animalFactsKey)),
            onStoryCompleted: { [weak self] payload in
                self?.pendingDemoStore.save(payload)
            }
        )

        guard let audio = try? RealAudioEngine() else {
            lastErrorMessage = "failed to configure audio session"
            return
        }
        audioEngine = audio
        audio.onDebugEvent = { [weak self] line in
            Task { @MainActor in self?.appendAudioDebugEvent(line) }
        }

        guard let vadModelPath = Bundle.main.path(forResource: "silero_vad", ofType: "onnx"),
              let vad = try? SileroVoiceActivityDetector(modelPath: vadModelPath) else {
            lastErrorMessage = "failed to load VAD model"
            return
        }

        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad, waitingDittyAudio: WaitingDitty.audio)
        self.coordinator = coordinator
        runLoop = Task { await coordinator.start() }

        let (micStream, micContinuation) = AsyncStream<Data>.makeStream()
        micStreamContinuation = micContinuation
        micConsumerTask = Task { [weak self] in
            for await pcm in micStream {
                await self?.coordinator?.captureAudio(pcm)
            }
        }

        do {
            try await audio.startCapturing { pcm in micContinuation.yield(pcm) }
        } catch {
            lastErrorMessage = "could not start audio capture: \(error.localizedDescription). Check Settings > Privacy > Microphone."
            disconnect()
            return
        }

        isConnected = true
        startPollingState()
    }

    func disconnect() {
        pollTask?.cancel()
        runLoop?.cancel()
        // Cancelling runLoop's Task alone does not stop the coordinator's
        // internal consume loops (see SessionCoordinator.close()'s doc
        // comment) -- without this, every Connect->Disconnect cycle leaked
        // the WebSocket connection, the coordinator's running Task, and
        // (transitively) this audioEngine instance. Capture the coordinator
        // before nilling it out below, since close() is async and this
        // method is not.
        let coordinatorToClose = coordinator
        Task { await coordinatorToClose?.close() }
        audioEngine?.stopCapturing()
        // Finish the mic pipe and stop its consumer -- mirrors the
        // coordinator teardown above: without this, every Connect-Disconnect
        // cycle would leak the consumer Task (it awaits `for await` on a
        // stream nobody ever finishes again).
        micStreamContinuation?.finish()
        micStreamContinuation = nil
        micConsumerTask?.cancel()
        micConsumerTask = nil
        coordinator = nil
        audioEngine = nil
        isConnected = false
        state = .idle
        // Reset so the UI doesn't show "Muted" against a fresh coordinator
        // (created unmuted by default) on the next connect().
        isMicMuted = false
        // Same reasoning -- a fresh coordinator starts at turn_id 0 with
        // an empty debug log, so mirror that here rather than showing
        // stale values from the coordinator that just went away.
        currentTurnId = 0
        coordinatorDebugLog = []
        audioDebugLog = []
        debugLog = []
        turns = []
        lastAppendedTranscriptTurnId = nil
        lastAppendedReplyTurnId = nil
    }

    /// What the "Disconnect" button calls -- a disconnect the user chose
    /// themselves must never be silently overridden by an auto-resume the
    /// next time they tap "Connect" (mirrors the existing reasoning for
    /// shouldReconnectOnForeground never being set here either).
    func disconnectUserInitiated() {
        pendingResumeTurnId = nil
        disconnect()
    }

    /// What the manual "Connect" button calls. Reads and clears
    /// pendingResumeTurnId -- exactly the same read-then-clear-then-pass
    /// pattern handleAppForegrounded() already uses for the backgrounding
    /// case -- so a plain reconnect after ANY kind of disconnect (not just
    /// backgrounding) correctly resumes whatever the server is still
    /// holding, instead of starting a fresh, memory-less session that
    /// discards the reply as belonging to a turn_id it no longer
    /// recognizes.
    func connectResumingIfPending() async {
        let resumingTurnId = pendingResumeTurnId
        pendingResumeTurnId = nil
        if awayFromHomeEnabled {
            await connectAwayFromHome()
        } else {
            await connect(resumingTurnId: resumingTurnId)
        }
    }

    /// Debug/testing affordance: abandon the current story and start a
    /// fresh one without disconnecting -- see SessionCoordinator.newStory().
    func startNewStory() async {
        guard let coordinator else { return }
        turns = []
        lastAppendedTranscriptTurnId = nil
        lastAppendedReplyTurnId = nil
        await coordinator.newStory()
    }

    /// Lets the child/parent mute the mic -- e.g. to prevent an accidental
    /// barge-in while waiting for a reply, or to unmute during that same
    /// window if they want to speak up anyway. Does NOT set isMicMuted
    /// directly: SessionCoordinator now also flips its own isMuted
    /// automatically (muted for the whole .waitingForReply window, unmuted
    /// the instant real reply audio starts), so this button is no longer
    /// the only thing that changes it -- isMicMuted has to be polled back
    /// from the coordinator (see startPollingState()) like state/
    /// transcript/etc. already are, or it would drift out of sync with
    /// (and could visually contradict) an in-flight automatic change.
    func toggleMute() {
        let coordinatorToUpdate = coordinator
        let newValue = !isMicMuted
        Task { await coordinatorToUpdate?.setMuted(newValue) }
    }

    /// Checks camera permission/availability before presenting the
    /// picker -- per the design spec's error handling, the button must
    /// be disabled or point to Settings rather than presenting a picker
    /// that can't work (e.g. no camera on the Simulator, or a denied
    /// permission).
    func requestCameraAccess() async -> Bool {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            // Routed to objectRecognitionHint, not lastErrorMessage --
            // lastErrorMessage is sticky by design for fatal connection/
            // audio errors (see startPollingState()'s disconnect handling
            // below), and a camera hiccup is a "try again" condition, not
            // session-fatal. Setting lastErrorMessage here would also risk
            // masking a later real disconnect, since the poller only fills
            // it in when it's still nil.
            objectRecognitionHint = "no camera available on this device."
            return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                // requestAccess resolves to false the first time the child
                // taps "Don't Allow" on the system prompt itself -- without
                // this, that path left no message at all and the button
                // just silently did nothing.
                objectRecognitionHint = "camera access denied. Check Settings > Privacy > Camera > TinyTalkApp."
            }
            return granted
        default:
            objectRecognitionHint = "camera access denied. Check Settings > Privacy > Camera > TinyTalkApp."
            return false
        }
    }

    /// Runs on-device classification and, on success, forwards the label
    /// to the server. Every failure path here (no confident label,
    /// Vision throwing, no active coordinator) ends in the same local
    /// "try again" hint rather than an error -- per the design spec, a
    /// failed or ambiguous photo attempt must never block or degrade the
    /// core voice turn, and a confusing error is worse than just letting
    /// the child try again.
    func handlePhotoTaken(_ image: UIImage) async {
        objectRecognitionHint = nil
        guard let coordinator else {
            objectRecognitionHint = "Couldn't quite tell what that is -- try again?"
            return
        }
        do {
            guard let recognized = try await objectRecognizer.recognize(image: image) else {
                objectRecognitionHint = "Couldn't quite tell what that is -- try again?"
                return
            }
            print("AppModel: recognized \(recognized.label) (confidence=\(recognized.confidence))")
            await coordinator.sendObjectSeen(label: recognized.label)
        } catch {
            print("AppModel: object recognition failed: \(error)")
            objectRecognitionHint = "Couldn't quite tell what that is -- try again?"
        }
    }

    /// Called when the app is backgrounded (phone locked, user switches
    /// apps, etc.) -- real on-device testing found the connection just
    /// dying uncleanly in this situation (iOS suspends the app; the mic/
    /// WebSocket/audio session don't get a chance to tear down properly,
    /// and by the time the app is reopened it's sitting in a stale,
    /// half-dead "Connected" state until the user notices and manually
    /// disconnects/reconnects). Disconnecting up front here, the instant
    /// backgrounding starts, is what makes that graceful instead of a
    /// silent failure discovered later. A no-op if not currently
    /// connected (nothing to tear down, and nothing to remember to
    /// restore on return).
    ///
    /// If a reply was in flight or already spoken when this happened
    /// (.waitingForReply or .speaking), the SERVER keeps generating/holding
    /// it regardless of this disconnect (see the server's
    /// SessionRunner.handle_disconnect()) -- capturing the coordinator's
    /// activeTurnId here is what lets handleAppForegrounded() ask for it
    /// back instead of the child returning to a silently-abandoned turn
    /// (previously read from `state`/a polled turn id refreshed only every
    /// 100ms by startPollingState() -- close enough for UI display, but a
    /// real gap for a one-shot decision made right as a turn transitions
    /// into .waitingForReply, which is exactly when backgrounding is most
    /// likely to happen). Switching this to an async, live actor read
    /// (rather than the stale polled value) was NOT sufficient on its own
    /// -- confirmed on real hardware (server logs showing a replayed reply
    /// discarded because the client's turn id was still 0, i.e. resume()
    /// was never even called) that the two actor reads below can still
    /// lose the race against iOS actually suspending the app, despite each
    /// individually being microseconds of work. beginBackgroundTask is
    /// Apple's own mechanism for "let this short critical section finish
    /// before suspending" -- requesting it here removes the guesswork
    /// about whether there's enough time, rather than hoping the OS
    /// schedules this Task promptly enough on its own.
    func handleAppBackgrounded() async {
        guard isConnected, let coordinator else { return }
        shouldReconnectOnForeground = true

        let backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "handleAppBackgrounded")
        defer { UIApplication.shared.endBackgroundTask(backgroundTaskId) }

        let liveState = await coordinator.state
        if liveState == .waitingForReply || liveState == .speaking {
            pendingResumeTurnId = await coordinator.activeTurnId
        } else {
            pendingResumeTurnId = nil
        }
        print("AppModel: backgrounded while \(liveState) -- pendingResumeTurnId=\(String(describing: pendingResumeTurnId))")
        disconnect()
    }

    /// Called when the app returns to the foreground. Only reconnects if
    /// handleAppBackgrounded() is what caused the prior disconnect --
    /// never overrides a disconnect the user chose themselves, or one the
    /// server side already caused. Reuses connect() as-is, so this gets
    /// exactly the same permission/error handling a manual reconnect
    /// would (e.g. if the Mac server or WiFi genuinely isn't reachable
    /// anymore, this surfaces the same clear error connect() already
    /// produces, rather than pretending to succeed). Passing
    /// pendingResumeTurnId through is what turns this from a fresh, memory-
    /// less reconnect into a resume of whatever the server was still
    /// holding for the child.
    func handleAppForegrounded() async {
        guard shouldReconnectOnForeground else { return }
        shouldReconnectOnForeground = false
        print("AppModel: foregrounded -- reconnecting with pendingResumeTurnId=\(String(describing: pendingResumeTurnId))")
        await connectResumingIfPending()
    }

    /// Appends one of RealAudioEngine's own diagnostic lines (already
    /// timestamped, see onDebugEvent's doc comment) and refreshes the
    /// merged debugLog. Capped independently at the same size as
    /// SessionCoordinator.debugLog for the same reason (bounded memory for
    /// a log that's read live, not archived).
    private func appendAudioDebugEvent(_ line: String) {
        audioDebugLog.append(line)
        if audioDebugLog.count > 50 {
            audioDebugLog.removeFirst(audioDebugLog.count - 50)
        }
        debugLog = mergedDebugLog()
    }

    /// Interleaves coordinatorDebugLog and audioDebugLog by their shared
    /// "[HH:mm:ss.SSS] ..." timestamp prefix (see DebugTimestamp) -- plain
    /// string sort works here because both prefixes are the same fixed
    /// width and zero-padded, so lexicographic order matches chronological
    /// order.
    private func mergedDebugLog() -> [String] {
        (coordinatorDebugLog + audioDebugLog).sorted()
    }

    private func startPollingState() {
        // Simple observation bridge from the actor's state to SwiftUI.
        // Fine for a bare-bones harness; not a pattern to scale up later.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let coordinator = self.coordinator else { return }
                let currentState = await coordinator.state
                let history = await coordinator.latencyHistory
                let transcript = await coordinator.lastTranscript
                let reply = await coordinator.lastReply
                let transcriptTurnId = await coordinator.lastTranscriptTurnId
                let replyTurnId = await coordinator.lastReplyTurnId
                let errorMessage = await coordinator.lastErrorMessage
                let closed = await coordinator.isClosed
                let muted = await coordinator.isMuted
                let turnId = await coordinator.activeTurnId
                let log = await coordinator.debugLog
                // Read regardless of `closed` (cheap, and reading it only
                // inside the `guard closed` branch below would still be
                // correct -- kept alongside the other coordinator reads
                // above for consistency). See resumableTurnIdAtDisconnect's
                // doc comment: this is already nil unless a reply was
                // genuinely in flight when the disconnect happened.
                let resumableTurnId = await coordinator.resumableTurnIdAtDisconnect
                // Returns "should this loop stop" as the closure's result,
                // rather than mutating a captured local var, since
                // MainActor.run's body is @Sendable and Swift 6 strict
                // concurrency rejects mutation of captured state from a
                // @Sendable closure even when (as here) it only ever runs
                // synchronously on this same task.
                let shouldStop: Bool = await MainActor.run {
                    self.state = currentState
                    self.latencyHistory = history
                    self.lastTranscript = transcript
                    self.lastReply = reply
                    self.isMicMuted = muted
                    self.currentTurnId = turnId
                    self.coordinatorDebugLog = log
                    self.debugLog = self.mergedDebugLog()
                    // Turn history for the story screen's chat view -- see
                    // StoryTurn's doc comment. Appends at most once per
                    // turn_id per speaker, keyed off the turn_id the
                    // transcript/reply TEXT ITSELF belongs to
                    // (lastTranscriptTurnId/lastReplyTurnId) -- NOT off
                    // activeTurnId/turnId (the CURRENT/latest turn), which
                    // can already have advanced to a new turn the instant
                    // the child starts talking again, before that new
                    // turn's own transcript/reply have arrived. Keying off
                    // activeTurnId was confirmed on real hardware to
                    // duplicate the previous bubble the moment the child
                    // spoke again, and then silently skip the real new
                    // turn once it did arrive (already marked "seen" under
                    // the wrong id) -- the UI appeared backed up by one
                    // turn. Keyed off turn_id rather than text equality so
                    // a repeated phrase (e.g. the child saying "hi" in two
                    // different turns) still gets its own bubble.
                    if !transcript.isEmpty, let transcriptTurnId, transcriptTurnId != self.lastAppendedTranscriptTurnId {
                        self.turns.append(StoryTurn(speaker: .child, text: transcript))
                        self.lastAppendedTranscriptTurnId = transcriptTurnId
                    }
                    if !reply.isEmpty, let replyTurnId, replyTurnId != self.lastAppendedReplyTurnId {
                        self.turns.append(StoryTurn(speaker: .elsie, text: reply))
                        self.lastAppendedReplyTurnId = replyTurnId
                    }
                    // Only overwrite with a real server error -- a nil here
                    // just means "no server error yet," and must not erase
                    // a client-side error (e.g. audio capture failing to
                    // start) that connect() already surfaced.
                    if let errorMessage {
                        self.lastErrorMessage = errorMessage
                    }
                    // The connection died: consumeServerEvents() saw
                    // `.closed` and walked the coordinator's own state back
                    // to .idle, but nothing else about that is visible to
                    // this UI on its own -- isConnected would stay stuck
                    // true forever, the button would keep saying
                    // "Disconnect", no error would appear, and mic capture
                    // would keep running while every send silently fails.
                    // Match the design spec: clear disconnected/error state
                    // on screen, mic capture stops, user must manually
                    // reconnect.
                    guard closed else { return false }
                    if self.lastErrorMessage == nil {
                        self.lastErrorMessage = "disconnected from server"
                    }
                    // Root-cause fix: this is the "randomly disconnects,
                    // then pressing Connect does nothing" scenario --
                    // capture whatever the coordinator determined was
                    // resumable BEFORE disconnect() discards this
                    // coordinator entirely, so the next manual "Connect"
                    // tap (connectResumingIfPending()) has something
                    // correct to resume instead of always starting fresh.
                    self.pendingResumeTurnId = resumableTurnId
                    print("AppModel: connection closed unexpectedly -- pendingResumeTurnId=\(String(describing: resumableTurnId))")
                    self.disconnect()
                    return true
                }
                if shouldStop { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// Thin SwiftUI wrapper around the standard system camera --
/// UIImagePickerController, not a custom AVCaptureSession preview, since
/// this is a single on-demand photo per the design spec, not a
/// continuous live view.
struct CameraPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            parent.onImagePicked(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
