import Foundation

/// A one-shot, mic-free fetch of the saved-story list over a connection the
/// caller owns for exactly this purpose -- e.g. a bare WebSocketServerConnection
/// opened without ever touching RealAudioEngine/VAD/SessionCoordinator, so
/// Landing can know its story count before the child has tapped anything
/// (see issue #41: the real server never requires mic/audio setup before
/// answering list_stories -- handle_connection is passive until a message
/// arrives -- so nothing about this needs the live-session machinery).
///
/// Always closes `connection` before returning, on every path (a real
/// answer, a `.closed` event, an unrelated send failure, or a timeout) --
/// the caller is expected to hand this a connection it never reuses.
/// Returns nil on anything short of a real answer; the caller's own
/// library state is left untouched, exactly like today's silent-retry
/// behavior for a cold launch with the home Mac unreachable.
public func peekStoryList(
    via connection: any ServerConnecting,
    timeout: Duration = .seconds(4)
) async -> [SavedStorySummary]? {
    defer { connection.close() }
    do {
        try await connection.send(.listStories)
    } catch {
        return nil
    }

    return await withTaskGroup(of: [SavedStorySummary]?.self) { group in
        group.addTask {
            for await event in connection.events() {
                if case .message(.storyList(let stories)) = event {
                    return stories
                }
                if case .closed = event {
                    return nil
                }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}
