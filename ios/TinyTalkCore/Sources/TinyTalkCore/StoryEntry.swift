import Foundation

/// The two buttons that open the story screen, and what each must do given
/// the session AppModel already has -- pulled out of AppModel so the rule
/// can be unit-tested.
///
/// They used to share one `startStory()` that only navigated whenever a
/// session was already connected (so Library's "+" tile, reachable
/// mid-story from Elsie's desk, wouldn't connect twice). Issue #64: after
/// The End -> Read it now -> Reading -> Library -> Home, the finished
/// story's session was still connected, so "Create a Story" silently
/// walked back into it -- the old bubbles stayed, no new_story was sent,
/// and SessionCoordinator.readyToShowTheEnd stayed latched from the first
/// story, so The End never appeared for the second.
public enum StoryEntry: Equatable, Sendable {
    /// Landing's "Create a Story": always a blank, new story.
    case homeCreateStory
    /// Library's "+ New story" tile: back into the story in progress if
    /// there is one, otherwise a new story.
    case libraryNewStoryTile

    public enum Action: Equatable, Sendable {
        /// No session yet -- connect, resuming whatever turn is pending
        /// (the pre-#64 path, unchanged).
        case connect
        /// No session yet, and the child asked for a blank, new story --
        /// connect fresh, then tell the server to drop whatever story it is
        /// still holding (issue #69: the server keeps one session across
        /// connections, so a new connection alone doesn't reset its
        /// conversation or story arc).
        case connectAndStartNewStory
        /// Just show the story screen; the live session carries on.
        case resumeLiveStory
        /// Abandon whatever the live session holds and start over on it
        /// (AppModel.startNewStory(): new_story on the wire, bubbles and
        /// The End's tracking cleared).
        case startNewStory
    }

    /// `liveStoryConcluded` is the coordinator's readyToShowTheEnd: true
    /// from the moment a story finishes until newStory() starts another.
    public func action(isConnected: Bool, liveStoryConcluded: Bool) -> Action {
        switch self {
        case .homeCreateStory:
            return isConnected ? .startNewStory : .connectAndStartNewStory
        case .libraryNewStoryTile:
            // No session: deliberately NOT a reset. Library can be open
            // mid-story after the connection dropped, with that story's
            // bubbles kept on screen (issue #23), and "+" means "back into
            // it" then.
            guard isConnected else { return .connect }
            return liveStoryConcluded ? .startNewStory : .resumeLiveStory
        }
    }
}
