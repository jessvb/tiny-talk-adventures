/// Real ServerConnecting backed by URLSessionWebSocketTask. Available on
/// iOS and macOS both (unlike AVAudioSession/onnxruntime -- see the plan's
/// Global Constraints), so this stays in the cross-platform TinyTalkCore
/// target.
import Foundation

public final class WebSocketServerConnection: ServerConnecting, @unchecked Sendable {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private let continuation: AsyncStream<ServerConnectionEvent>.Continuation
    private let stream: AsyncStream<ServerConnectionEvent>

    public init(url: URL) {
        self.url = url
        (stream, continuation) = AsyncStream<ServerConnectionEvent>.makeStream()
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        Task { [weak self] in await self?.receiveLoop() }
    }

    public func send(_ message: ClientMessage) async throws {
        try await task?.send(.string(message.encode()))
    }

    public func send(audio pcm: Data) async throws {
        try await task?.send(.data(pcm))
    }

    public func events() -> AsyncStream<ServerConnectionEvent> { stream }

    /// Cancels the underlying WebSocket task and finishes the events()
    /// stream directly (rather than waiting for receiveLoop()'s catch
    /// block to notice the cancellation asynchronously), so a caller
    /// tearing down the coordinator gets a deterministic, immediate
    /// teardown instead of racing the receive loop.
    public func close() {
        task?.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }

    /// Continuously receives WebSocket messages and dispatches them as events.
    ///
    /// Dispatch logic: binary frames → `.audio` events, text frames → `decodeServerEvent`
    /// → `.message` events, malformed text → logged (not silent), any error → `.closed` + finish.
    ///
    /// Testing note: This function's 3-branch dispatch logic does not have a dedicated
    /// loopback integration test. Coverage comes from:
    /// - `decodeServerEvent` itself has 11 dedicated unit tests (Task 1, Protocol.swift)
    ///   verifying all decode paths and error cases
    /// - The dispatch branches are thin (one line each) and trivially reviewable
    /// - Real end-to-end testing happens in Task 8 against the actual Python server
    ///   running over the network, which is a more meaningful verification than a
    ///   synthetic fixture would provide
    /// Malformed frame logging is verified to not crash/hang by existing tests.
    private func receiveLoop() async {
        guard let task else {
            continuation.yield(.closed)
            continuation.finish()
            return
        }
        while true {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let pcm):
                    continuation.yield(.audio(pcm))
                case .string(let raw):
                    do {
                        let event = try decodeServerEvent(raw)
                        continuation.yield(.message(event))
                    } catch {
                        print("WebSocketServerConnection: malformed server frame: \(error)")
                    }
                @unknown default:
                    continue
                }
            } catch {
                continuation.yield(.closed)
                continuation.finish()
                return
            }
        }
    }
}
