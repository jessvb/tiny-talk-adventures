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
    /// Overrides AVSpeechTts's own Matilda-then-en-US default (see
    /// resolveVoice()'s doc comment) -- a household wants to experiment
    /// with alternatives. nil means "use that default," not "no voice."
    /// Persisted the same way serverAddress is; read fresh at the start
    /// of every connectAwayFromHome() (see that method), same as
    /// awayFromHomeEnabled -- there is no live-update path since
    /// on-device TTS has no analog to updateSettings() over the wire.
    @Published var selectedVoiceIdentifier: String?
    /// Parent-adjustable story length -- see docs/superpowers/specs/
    /// 2026-09-09-story-length-settings-design.md. Persisted the same
    /// way serverAddress is; sent to the server on every connect() and
    /// immediately on every change while connected (updateStorySettings()
    /// below). Applies to the NEXT story only -- never retroactively.
    @Published var storyTurnCount: Int
    @Published var storybookPageCount: Int
    /// The mic must only actively listen on .creating -- see issue #31.
    /// `screen` is set directly from ~15 call sites across every View file
    /// (Settings' preview buttons, Library/Reading navigation, The End's
    /// auto-nav, etc.), and only goHome() happened to disconnect (which
    /// incidentally muted too). Centralizing the mute/unmute here, rather
    /// than adding a call at each of those sites, matches AppScreen's own
    /// doc comment about why navigation lives on AppModel instead of a
    /// NavigationStack -- and guarantees nothing can introduce a new
    /// `screen = ...` site that forgets it. Safe to call unconditionally:
    /// isMuted is already a transient flag the coordinator itself flips
    /// automatically across turn boundaries (see toggleMute()'s doc
    /// comment), not a durable user preference, and a nil coordinator
    /// (not yet connected) no-ops via the optional.
    @Published var screen: AppScreen {
        didSet {
            guard screen != oldValue else { return }
            let shouldBeMuted = screen != .creating
            let coordinatorToMute = coordinator
            Task { await coordinatorToMute?.setMuted(shouldBeMuted) }
        }
    }
    /// Where LibraryView's back button returns to -- Library is reachable
    /// both from Landing (possibly disconnected, see refreshLibrary()'s
    /// on-demand reconnect) and from Elsie's desk mid-story (already
    /// connected, session running in the background). Deliberately NOT
    /// derived from isConnected the way SettingsView's equivalent back
    /// button is: Library's own reconnect can make isConnected true again
    /// for a visit that started from Landing, which would make isConnected
    /// alone indistinguishable from "came from a live story." Every screen
    /// that navigates to .library sets this explicitly rather than relying
    /// on the .landing default, since AppModel is one long-lived instance
    /// across the whole session.
    var libraryReturnScreen: AppScreen = .landing
    @Published var state: SessionState = .idle
    @Published var lastTranscript: String = ""
    @Published var lastReply: String = ""
    @Published var lastErrorMessage: String?
    @Published var latencyHistory: [InterruptLatency] = []
    @Published var isConnected = false
    @Published var isMicMuted = false
    @Published var objectRecognitionHint: String?
    @Published var turns: [StoryTurn] = []
    /// The Library screen's real saved-story list -- populated from the
    /// server's real list_stories() response via startPollingState()'s
    /// poll loop (see AppModel.swift's poll loop and refreshLibrary()).
    @Published var libraryStories: [SavedStorySummary] = []
    /// The story currently shown by TheEndView/ReadingView -- populated by
    /// whichever screen navigates to them (a Library card tap, or a
    /// Settings preview button).
    @Published var selectedStory: SavedStoryDetail?
    /// Fetched page images for the currently-open story, keyed by
    /// "storyId#pageIndex" -- see requestPageImage() and
    /// startPollingState()'s pageImage handling below. Never cleared
    /// mid-session; a stale entry for a story the child has moved on
    /// from is harmless (ReadingView only ever reads the key for its
    /// own selectedStory).
    @Published private(set) var pageImages: [String: Data] = [:]
    /// Mirrors the coordinator's isRewriting -- a UI (TheEndView) polls
    /// this to show/hide a "still being created" state.
    @Published var isRewriting = false
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
    /// True once this coordinator's readyToShowTheEnd has been seen and
    /// listStories() requested for it -- guards against asking twice on
    /// every 100ms poll tick while waiting for the response. Reset on
    /// disconnect() (a torn-down coordinator can never deliver a pending
    /// request), NOT on startNewStory() (readyToShowTheEnd only ever
    /// fires once per coordinator regardless).
    private var pendingTheEndLookup = false
    /// Set the instant a story-detail fetch is kicked off -- either
    /// automatically (a story just concluded, see the readyToShowTheEnd
    /// handling below) or manually (a Library card tap, see openStory()
    /// below) -- and cleared once the matching storyDetail arrives. Guards
    /// against starting a second fetch while one is already in flight (see
    /// both call sites). Reset on disconnect() for the same reason as
    /// pendingTheEndLookup: a torn-down coordinator can never deliver on it.
    private var pendingStoryDetailFetchId: String?
    /// The story_id The End screen has already been shown for, this app
    /// lifetime -- deliberately NOT reset on disconnect(): its whole
    /// purpose is surviving the coordinator teardown a backgrounding-
    /// triggered disconnect causes (see handleAppForegrounded()), so a
    /// story already shown once doesn't re-trigger navigation on a later,
    /// unrelated reconnect.
    private var lastAcknowledgedConcludedStoryId: String?
    /// True once this AppModel instance has processed at least one
    /// listStories() response. Guards the very first response of a
    /// session from being misread as "a story just concluded" by the
    /// block below -- lastAcknowledgedConcludedStoryId starts nil on
    /// every fresh AppModel/coordinator, so without this, connect()'s own
    /// listStories() trigger (added to keep Landing's button accurate)
    /// made the FIRST-EVER story list response of a session
    /// indistinguishable from a genuine conclusion, hijacking navigation
    /// to The End for an old, unrelated story mid-live-session. Never
    /// reset by disconnect() -- a background/foreground cycle within the
    /// same app process must NOT re-trigger this baseline-seeding path,
    /// since that path (handleAppForegrounded's own listStories() call)
    /// is exactly the one that's supposed to detect a real conclusion
    /// that happened while backgrounded.
    private var hasEstablishedLibraryBaseline = false
    /// The last value of coordinator.lastErrorMessage this poll loop
    /// observed (including nil) -- see its use in startPollingState()'s
    /// error handling. Lets that code detect the EDGE where a new error
    /// first appears, rather than reacting to "an error exists" as if it
    /// were a fresh event on every single poll tick.
    private var lastObservedCoordinatorErrorMessage: String?
    /// isRewriting from the PREVIOUS poll tick -- lets the poll loop
    /// detect the true->false edge (rewriting_done just arrived) rather
    /// than re-fetching on every tick while it happens to be false.
    /// Starts false to match a fresh coordinator's own isRewriting
    /// default, so the very first poll tick after any connect() can
    /// never look like a spurious true->false transition.
    private var previousIsRewriting = false

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
        awayFromHomeEnabled = UserDefaults.standard.bool(forKey: "awayFromHomeEnabled")
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceIdentifier")
        let storedTurnCount = UserDefaults.standard.integer(forKey: "storyTurnCount")
        storyTurnCount = storedTurnCount == 0 ? 7 : storedTurnCount
        let storedPageCount = UserDefaults.standard.integer(forKey: "storybookPageCount")
        storybookPageCount = storedPageCount == 0 ? 5 : storedPageCount
        let hasOnboarded = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        screen = hasOnboarded ? .landing : .onboarding
    }

    /// The Settings toggle calls this (not $awayFromHomeEnabled directly)
    /// so the choice survives an app relaunch, matching serverAddress's
    /// own persistence. Also disconnects if a connection is already live:
    /// the connection type is only ever chosen once, at connect time (see
    /// connectResumingIfPending()) -- nothing re-evaluates it while
    /// already connected. Without this, flipping the toggle mid-session
    /// (reachable from StoryView's own menu) silently kept talking to the
    /// OLD backend while every "connected" status text (which reads this
    /// flag, not which connection is actually live) claimed otherwise --
    /// caught on-device: toggling away-from-home off produced no server
    /// logs, no saved story, and the same on-device TTS audio as before.
    /// A story's conversation state has no meaning across a backend
    /// switch anyway (Groq and the home server are unrelated brains), so
    /// disconnecting and forcing a fresh connect on the next "Create a
    /// Story" is the correct behavior, not just an acceptable side effect
    /// -- and disconnecting mid-story is already a supported path (see
    /// disconnectUserInitiated(), which the "Home" menu item already
    /// calls from the same screens this can fire from).
    func setAwayFromHomeEnabled(_ enabled: Bool) {
        let changingWhileConnected = enabled != awayFromHomeEnabled && isConnected
        awayFromHomeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "awayFromHomeEnabled")
        if changingWhileConnected {
            disconnect()
        }
    }

    /// Settings' voice picker calls this. Unlike setAwayFromHomeEnabled(),
    /// does not disconnect an in-progress session -- the current
    /// connection's AVSpeechTts already captured whichever voice was
    /// selected at connect time (see connectAwayFromHome()) and there is
    /// no misleading status text at stake the way there is for the
    /// away-from-home toggle, so this takes effect on the next story
    /// only, matching storyLengthCard's own "next story" copy.
    func setSelectedVoiceIdentifier(_ identifier: String?) {
        selectedVoiceIdentifier = identifier
        UserDefaults.standard.set(identifier, forKey: "selectedVoiceIdentifier")
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

    /// What Landing's "Create a Story" button and Library's "+ New story"
    /// tile both call. Reuses connectResumingIfPending() as-is so
    /// backgrounding/resume behavior is identical regardless of which
    /// screen initiated the connect. Guarded on isConnected: Library's "+"
    /// tile is now reachable while ALREADY connected (via Elsie's desk's
    /// own "Library" menu item, which navigates there without
    /// disconnecting) -- without this guard, tapping it mid-story would
    /// call connect() a second time on top of the live coordinator,
    /// leaking its WebSocket/audio engine/Task and double-capturing the
    /// mic rather than just returning to the story already in progress.
    /// The live session keeps running via startPollingState()'s poll loop
    /// regardless of which screen is on-screen, so simply navigating back
    /// to .creating is enough to resume it.
    func startStory() async {
        screen = .creating
        guard !isConnected else { return }
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
        // The server's per-session settings default to its own config
        // constants until told otherwise -- send the parent's current
        // preference now so even the very first story of this connection
        // uses it, not just the second one onward.
        Task { await coordinator.updateSettings(targetTurns: storyTurnCount, pageCount: storybookPageCount) }
        // So Landing's "Read Stories" button (LandingView.swift) is
        // accurate from a cold launch, not just after a background/
        // foreground cycle or a concluded story -- a story saved in a
        // PREVIOUS session shouldn't require either of those first.
        Task { await coordinator.listStories() }
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
        let ttsClient = AVSpeechTts(voiceIdentifier: selectedVoiceIdentifier)
        // Same on-screen debug log as connection.onDebugEvent below --
        // see AVSpeechTts.onDebugEvent's own doc comment for why this
        // exists (diagnosing a resolved-wrong-voice report).
        ttsClient.onDebugEvent = { [weak self] line in
            Task { @MainActor in self?.appendAudioDebugEvent(line) }
        }
        let connection = DemoConnection(
            chatClient: GroqChatClient(apiKey: groqKey),
            sttClient: GroqWhisperClient(apiKey: groqKey),
            ttsClient: ttsClient,
            animalFactTracker: AnimalFactTracker(fetcher: AnimalFactsAPIClient(apiKey: animalFactsKey)),
            onStoryCompleted: { [weak self] payload in
                self?.pendingDemoStore.save(payload)
            }
        )
        // Merge DemoConnection's own diagnostic lines into the same
        // on-screen debug log as RealAudioEngine's -- see connect()'s
        // audio.onDebugEvent wiring above for the same pattern. Hops onto
        // the main actor since appendAudioDebugEvent mutates @Published
        // state; the hook itself can fire from a background Task, not
        // necessarily the main thread.
        connection.onDebugEvent = { [weak self] line in
            Task { @MainActor in self?.appendAudioDebugEvent(line) }
        }

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
        // A torn-down coordinator can never deliver on either pending
        // request -- see their doc comments. lastAcknowledgedConcludedStoryId
        // is deliberately NOT reset here.
        pendingTheEndLookup = false
        pendingStoryDetailFetchId = nil
        isRewriting = false
        previousIsRewriting = false
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

    /// What the "Finish this story" menu item calls -- see
    /// SessionCoordinator.concludeStory(). Bypasses the model's own
    /// phrase-matching entirely: the server forces a real final reply
    /// and marks the story done unconditionally.
    func finishStory() async {
        guard let coordinator else { return }
        await coordinator.concludeStory()
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

    /// What ReadingView calls (once per visible page) to fetch that page's
    /// illustration -- see pageImages' doc comment. Guarded against
    /// re-requesting a key already present so a page staying on screen
    /// across poll ticks/re-renders doesn't spam the server with duplicate
    /// getPageImage() calls for the same image.
    func requestPageImage(storyId: String, pageIndex: Int) {
        let key = "\(storyId)#\(pageIndex)"
        guard pageImages[key] == nil else { return }
        Task { [weak self] in
            await self?.coordinator?.getPageImage(storyId: storyId, pageIndex: pageIndex)
        }
    }

    /// What ReadingView's 🔊 button calls -- combines stopPageAudio() and
    /// the synthesizePage() request into ONE ordered Task, rather than
    /// launching two independent unstructured Tasks with no guaranteed
    /// ordering between them (which is what a bare stopPageAudio() +
    /// requestPageAudio() call pair would do). The two calls must happen
    /// in this exact order on the same actor: stop's cleanup (clearing
    /// pendingPageAudioRequest and incrementing the discard counter for
    /// any still-in-flight leftover audio) must land before the new
    /// request is sent, or the new request's own pendingPageAudioRequest
    /// assignment could be clobbered by a stop that was meant for the
    /// PREVIOUS tap. No dedup guard: unlike an image (fetched once,
    /// cached), each tap should always actually play audio again, even
    /// for a page already heard.
    func replayPageAudio(storyId: String, pageIndex: Int) {
        Task { [weak self] in
            guard let coordinator = self?.coordinator else { return }
            await coordinator.stopPageAudio()
            await coordinator.synthesizePage(storyId: storyId, pageIndex: pageIndex)
        }
    }

    /// What ReadingView calls on page change/disappear to stop whatever
    /// page audio is currently playing or pending -- see
    /// SessionCoordinator.stopPageAudio()'s doc comment.
    func stopPageAudio() {
        Task { [weak self] in
            await self?.coordinator?.stopPageAudio()
        }
    }

    /// What LibraryView calls when the child taps a `.done` story card --
    /// mirrors the automatic fetch startPollingState() already does when a
    /// story concludes (see pendingStoryDetailFetchId's doc comment): show
    /// a pending placeholder immediately, navigate, then let the poll loop
    /// overwrite selectedStory once the real detail arrives. Guards against
    /// stomping an already-in-flight fetch, same as the automatic trigger.
    func openStory(_ summary: SavedStorySummary) {
        // Require a live coordinator before committing to any of this --
        // without it, this would navigate into a permanently-blank
        // Reading screen and wedge pendingStoryDetailFetchId forever
        // (nothing can ever clear it: no connection means no
        // story_detail will arrive, and no error frame will arrive
        // either), silently blocking The End's auto-navigation for the
        // NEXT story too.
        guard pendingStoryDetailFetchId == nil, let coordinator else { return }
        selectedStory = SavedStoryDetail(
            id: summary.id, title: summary.title, pages: [], epilogue: nil, rewriteStatus: summary.rewriteStatus
        )
        screen = .reading
        pendingStoryDetailFetchId = summary.id
        Task {
            await coordinator.getStory(storyId: summary.id)
        }
    }

    /// What LibraryView calls on appear, so opening Library is always
    /// fresh rather than depending on having recently backgrounded or
    /// concluded a story (the two triggers that otherwise populate
    /// libraryStories, see startPollingState()). Also Library's reconnect
    /// entry point: "Home" (goHome()) always disconnects (see its own doc
    /// comment), which used to leave a nil coordinator here with no
    /// recovery -- openStory()'s own coordinator guard would then silently
    /// no-op on every card tap, with zero feedback to the child. Reuses
    /// the same connectResumingIfPending() reconnect Landing's "Create a
    /// Story" already relies on; connect()'s own post-connect steps
    /// already call listStories(), so no separate fetch is needed once it
    /// completes. Guarded on `coordinator == nil` rather than `isConnected`
    /// because connect() sets `coordinator` synchronously well before
    /// isConnected flips true (see connect()'s own ordering) -- checking
    /// isConnected here would let a second onAppear during that window
    /// kick off a duplicate connect.
    func refreshLibrary() {
        guard let coordinator else {
            Task { [weak self] in await self?.connectResumingIfPending() }
            return
        }
        Task { await coordinator.listStories() }
    }

    /// What Settings' story-length steppers call on every change -- see
    /// storyTurnCount's doc comment. Persists immediately regardless of
    /// connection state; sends to the server immediately only if already
    /// connected (otherwise the persisted values go out via connect()'s
    /// own send below, on the next connection).
    func updateStorySettings(turnCount: Int, pageCount: Int) {
        storyTurnCount = turnCount
        storybookPageCount = pageCount
        UserDefaults.standard.set(turnCount, forKey: "storyTurnCount")
        UserDefaults.standard.set(pageCount, forKey: "storybookPageCount")
        guard isConnected, let coordinator else { return }
        Task { await coordinator.updateSettings(targetTurns: turnCount, pageCount: pageCount) }
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
        // Captured before connectResumingIfPending() clears it: nil here
        // means nothing was mid-turn when this app backgrounded -- which
        // is also exactly the state a story left behind once it
        // concluded (turnEnd already walked the client back to .idle
        // before REWRITING, a server-only concept, ever begins). If the
        // story finished concluding (or finished its whole rewrite)
        // while this app was away, the OLD coordinator's readyToShowTheEnd
        // never got the chance to fire locally -- backgrounding tore that
        // coordinator down before it could. The check below, on the
        // FRESH coordinator, is the only remaining way to discover it.
        let wasResumingATurn = pendingResumeTurnId != nil
        print("AppModel: foregrounded -- reconnecting with pendingResumeTurnId=\(String(describing: pendingResumeTurnId))")
        await connectResumingIfPending()
        if !wasResumingATurn {
            await coordinator?.listStories()
        }
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
                let rewriting = await coordinator.isRewriting
                let readyToShowTheEnd = await coordinator.readyToShowTheEnd
                let storyList = await coordinator.latestStoryList
                let storyDetail = await coordinator.latestStoryDetail
                let coordinatorPageImages = await coordinator.pageImages
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
                    // Self-healing companion to screen's own didSet (see its
                    // doc comment): on-device testing (issue #31) found that
                    // one-shot mute can lose a narrow race against the
                    // concluding turn's own turnEnd-driven setMuted(false)
                    // if speech starts right as `screen` changes -- confirmed
                    // by testing that waiting a few seconds before speaking
                    // avoided it, meaning the mute eventually wins, just not
                    // immediately. Reasserting here, once per ~100ms poll
                    // tick, means a lost race self-corrects within one tick
                    // instead of staying lost until the next screen change.
                    if self.screen != .creating, !muted {
                        Task { await coordinator.setMuted(true) }
                    }
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
                    self.isRewriting = rewriting

                    // Library's real data source: every listStories()
                    // response (fired today by the readyToShowTheEnd
                    // trigger below, handleAppForegrounded(), connect()'s
                    // initial fetch, and refreshLibrary() below) lands
                    // here -- nothing about this assignment cares which
                    // trigger caused it.
                    if let storyList {
                        self.libraryStories = storyList
                    }

                    // The story just concluded and both signals have
                    // combined (see SessionCoordinator.readyToShowTheEnd's
                    // doc comment) -- kick off the lookup exactly once
                    // per coordinator.
                    if readyToShowTheEnd, !self.pendingTheEndLookup {
                        self.pendingTheEndLookup = true
                        Task { await coordinator.listStories() }
                    }

                    // A fresh story list arrived, from any of the four
                    // triggers named above -- newest entry first (matches
                    // story_store.list_stories()'s own ordering). The
                    // FIRST such list of this AppModel's lifetime only
                    // establishes what "already existed" looks like; every
                    // list after it is checked for a newly-concluded story
                    // to navigate to. Only act once per concluded story
                    // (lastAcknowledgedConcludedStoryId guards this -- its
                    // whole purpose is surviving a coordinator teardown,
                    // see its own doc comment), and only start a detail
                    // request if one isn't already in flight.
                    if let storyList, !self.hasEstablishedLibraryBaseline {
                        // The very first list this AppModel instance has
                        // ever seen -- seed the baseline without
                        // navigating. See hasEstablishedLibraryBaseline's
                        // doc comment for why: this list's newest entry
                        // might be an old story from a previous session,
                        // not something that just concluded.
                        self.hasEstablishedLibraryBaseline = true
                        self.lastAcknowledgedConcludedStoryId = storyList.first?.id
                    } else if let newest = storyList?.first,
                       newest.id != self.lastAcknowledgedConcludedStoryId,
                       self.pendingStoryDetailFetchId == nil {
                        self.pendingStoryDetailFetchId = newest.id
                        self.lastAcknowledgedConcludedStoryId = newest.id
                        // Show The End immediately with a pending
                        // placeholder -- "right after the last message
                        // is finished being spoken," per the design, not
                        // once the rewrite (which can still be in
                        // progress) finishes. The getStory() request
                        // below fills in the real detail (possibly
                        // already .done) as soon as it arrives.
                        self.selectedStory = SavedStoryDetail(id: newest.id, title: nil, pages: [], epilogue: nil, rewriteStatus: .pending)
                        if self.screen != .theEnd {
                            self.screen = .theEnd
                        }
                        let storyId = newest.id
                        Task { await coordinator.getStory(storyId: storyId) }
                    }

                    // The detail request above (or the re-fetch below)
                    // has answered -- update selectedStory in place so a
                    // live TheEndView reflects it (un-greys Read-it-now
                    // once rewriteStatus flips to .done/.failed) without
                    // ever leaving the screen.
                    if let storyDetail, storyDetail.id == self.pendingStoryDetailFetchId {
                        self.pendingStoryDetailFetchId = nil
                        self.selectedStory = storyDetail
                    } else if let storyDetail, self.screen == .theEnd, storyDetail.id == self.selectedStory?.id {
                        self.selectedStory = storyDetail
                    }

                    // Union merge: every key the coordinator has accumulated
                    // that isn't already here gets copied over. Reading the
                    // coordinator's own accumulating dictionary (rather than
                    // a single "latest" value) is what makes this safe when
                    // more than one page-image request is in flight at
                    // once -- see SessionCoordinator.pageImages' doc
                    // comment for why a single-slot design used to lose
                    // whichever request's response arrived first.
                    for (key, data) in coordinatorPageImages where self.pageImages[key] == nil {
                        self.pageImages[key] = data
                    }

                    // The rewrite just finished (isRewriting's true->false
                    // edge) while The End screen is showing this story's
                    // placeholder -- re-fetch, since the getStory() call
                    // fired the instant the placeholder appeared may have
                    // raced ahead of the rewrite actually completing and
                    // so still holds a stale .pending detail.
                    if self.previousIsRewriting, !rewriting, self.screen == .theEnd,
                       let storyId = self.selectedStory?.id, self.pendingStoryDetailFetchId == nil {
                        self.pendingStoryDetailFetchId = storyId
                        Task { await coordinator.getStory(storyId: storyId) }
                    }
                    self.previousIsRewriting = rewriting

                    // Only overwrite with a real server error -- a nil here
                    // just means "no server error yet," and must not erase
                    // a client-side error (e.g. audio capture failing to
                    // start) that connect() already surfaced.
                    // coordinator.lastErrorMessage is a STICKY latest
                    // value (cleared only when a new story starts
                    // server-side), not a one-shot event -- reacting to
                    // "errorMessage != nil" unconditionally on every
                    // ~100ms poll tick would clear pendingStoryDetailFetchId
                    // over and over for the rest of the story after a
                    // single error, permanently discarding any later
                    // Library-tap fetch's real response the instant it
                    // arrived (it could never match a flag that keeps
                    // getting nulled out). React only the one tick the
                    // value actually changes.
                    if errorMessage != self.lastObservedCoordinatorErrorMessage {
                        if errorMessage != nil {
                            // A pending story-detail fetch can never be
                            // resolved by an error frame (no story_detail
                            // will follow it) -- clear it so a stale,
                            // permanently-unresolvable fetch doesn't block
                            // every future Library tap or The End
                            // auto-navigation. Only done on the edge where
                            // this specific error first appears, not on
                            // every later tick it's still the current
                            // sticky value.
                            self.pendingStoryDetailFetchId = nil
                        }
                    }
                    if let errorMessage {
                        self.lastErrorMessage = errorMessage
                    }
                    self.lastObservedCoordinatorErrorMessage = errorMessage
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
