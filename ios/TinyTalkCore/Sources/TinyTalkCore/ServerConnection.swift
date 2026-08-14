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
