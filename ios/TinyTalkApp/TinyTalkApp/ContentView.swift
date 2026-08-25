import SwiftUI
import TinyTalkCore
import TinyTalkPlatform

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

    private var coordinator: SessionCoordinator?
    private var audioEngine: RealAudioEngine?
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

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
    }

    func connect() async {
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
            try audio.startCapturing { pcm in
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

struct ContentView: View {
    @StateObject private var model = AppModel()

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
            }

            Text("State: \(String(describing: model.state))")
                .font(.headline)

            if let error = model.lastErrorMessage {
                Text("Error: \(error)").foregroundColor(.red)
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
    }
}
