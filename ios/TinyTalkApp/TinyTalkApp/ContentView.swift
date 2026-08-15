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

    private var coordinator: SessionCoordinator?
    private var audioEngine: RealAudioEngine?
    private var runLoop: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init() {
        serverAddress = UserDefaults.standard.string(forKey: "serverAddress") ?? "ws://192.168.1.1:8765"
    }

    func connect() {
        UserDefaults.standard.set(serverAddress, forKey: "serverAddress")
        guard let url = URL(string: serverAddress) else {
            lastErrorMessage = "invalid server address"
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

        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        self.coordinator = coordinator
        runLoop = Task { await coordinator.start() }

        do {
            try audio.startCapturing { [weak self] pcm in
                Task { await self?.coordinator?.captureAudio(pcm) }
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
        coordinator = nil
        audioEngine = nil
        isConnected = false
        state = .idle
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
                await MainActor.run {
                    self.state = currentState
                    self.latencyHistory = history
                    self.lastTranscript = transcript
                    self.lastReply = reply
                    // Only overwrite with a real server error -- a nil here
                    // just means "no server error yet," and must not erase
                    // a client-side error (e.g. audio capture failing to
                    // start) that connect() already surfaced.
                    if let errorMessage {
                        self.lastErrorMessage = errorMessage
                    }
                }
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
                model.isConnected ? model.disconnect() : model.connect()
            }

            Text("State: \(String(describing: model.state))")
                .font(.headline)

            if let error = model.lastErrorMessage {
                Text("Error: \(error)").foregroundColor(.red)
            }

            Text("Heard: \(model.lastTranscript)")
            Text("Reply: \(model.lastReply)")

            List(Array(model.latencyHistory.enumerated()), id: \.offset) { _, latency in
                Text(String(format: "VAD→stopped: %.1fms", latency.vadFireToPlaybackStoppedMillis))
            }

            Spacer()
        }
        .padding()
    }
}
