import AVFoundation
import SwiftUI
import TinyTalkCore
import TinyTalkPlatform
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var serverAddress: String
    @Published var state: SessionState = .idle
    @Published var lastTranscript: String = ""
    @Published var lastReply: String = ""
    @Published var lastErrorMessage: String?
    @Published var latencyHistory: [InterruptLatency] = []
    @Published var isConnected = false
    @Published var isMicMuted = false
    @Published var objectRecognitionHint: String?

    private var coordinator: SessionCoordinator?
    private var audioEngine: RealAudioEngine?
    private let objectRecognizer = VisionObjectRecognizer()
    private var runLoop: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
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
    /// Set by handleAppBackgrounded() when the backgrounded turn was still
    /// live (.waitingForReply or .speaking) -- handleAppForegrounded() hands
    /// this to connect(resumingTurnId:) so the reply that was in flight (or
    /// already finished but never heard) can be resumed/replayed instead of
    /// starting a silent fresh session. nil for a backgrounding that
    /// happened while .idle or .listening, where there is nothing to resume.
    private var pendingResumeTurnId: Int?

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
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
        let resumingTurnId = pendingResumeTurnId
        pendingResumeTurnId = nil
        print("AppModel: foregrounded -- reconnecting with resumingTurnId=\(String(describing: resumingTurnId))")
        await connect(resumingTurnId: resumingTurnId)
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
                let errorMessage = await coordinator.lastErrorMessage
                let closed = await coordinator.isClosed
                let muted = await coordinator.isMuted
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

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingCamera = false

    var body: some View {
        VStack(spacing: 16) {
            TextField("ws://<mac-ip>:8765", text: $model.serverAddress)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isConnected)

            Button(model.isConnected ? "Disconnect" : "Connect") {
                if model.isConnected {
                    model.disconnect()
                } else {
                    Task { await model.connect() }
                }
            }

            if model.isConnected {
                Button {
                    model.toggleMute()
                } label: {
                    Label(
                        model.isMicMuted ? "Muted" : "Mute Mic",
                        systemImage: model.isMicMuted ? "mic.slash.fill" : "mic.fill"
                    )
                }
                .tint(model.isMicMuted ? .red : .accentColor)

                Button {
                    Task {
                        guard await model.requestCameraAccess() else { return }
                        showingCamera = true
                    }
                } label: {
                    Label("Show Me Something", systemImage: "camera.fill")
                }
            }

            Text("State: \(String(describing: model.state))")
                .font(.headline)

            if let error = model.lastErrorMessage {
                Text("Error: \(error)").foregroundColor(.red)
            }

            if let hint = model.objectRecognitionHint {
                Text(hint).foregroundColor(.secondary)
            }

            Text("Heard: \(model.lastTranscript)")
                .fixedSize(horizontal: false, vertical: true)

            // The reply's own List sibling below is a flexible view that
            // otherwise squeezes this Text down to ~3 visible lines even
            // with no explicit lineLimit -- fixedSize forces it to take
            // its full natural height instead of being compressed, and
            // the ScrollView (capped, not full-screen) guarantees the
            // whole reply is reachable even if it ever runs long enough
            // to exceed the visible area.
            ScrollView {
                Text("Reply: \(model.lastReply)")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)

            List(Array(model.latencyHistory.enumerated()), id: \.offset) { _, latency in
                Text(String(format: "VAD→stopped: %.1fms", latency.vadFireToPlaybackStoppedMillis))
            }

            Spacer()
        }
        .padding()
        // Single-value closure (not the two-value oldValue/newValue form,
        // which needs iOS 17+ -- this project's deployment target is 16,
        // see project.yml) -- no need to compare against a previous
        // phase anyway, since handleAppForegrounded() already guards
        // internally on whether IT was the one that disconnected. Only
        // .background (not the momentary .inactive that happens e.g.
        // pulling down Control Center) triggers a disconnect -- reacting
        // to .inactive too would disconnect/reconnect on every brief
        // interruption, far more disruptive than the problem this fixes.
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                Task { await model.handleAppBackgrounded() }
            case .active:
                Task { await model.handleAppForegrounded() }
            default:
                break
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker(
                onImagePicked: { image in
                    showingCamera = false
                    Task { await model.handlePhotoTaken(image) }
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
    }
}
