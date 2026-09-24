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
    /// Library's "+ New story" tile, Library opened from a live story
    /// (Elsie's desk): back into the story in progress if there is one,
    /// otherwise a new story.
    case libraryNewStoryTile
    /// Library's "+ New story" tile, Library opened from Home: always a
    /// blank, new story, exactly like Home's own button. Issue #69: Library's
    /// onAppear reconnects on its own, so the plain tile saw a live session
    /// whose fresh coordinator hadn't concluded anything and "resumed" it --
    /// a blank screen while the server carried on with the story abandoned
    /// via Home. Reached from Home, nothing is on screen to go back into.
    case libraryNewStoryTileOpenedFromHome

    /// Which tile case Library's "+" is, given where Library was opened
    /// from (AppModel.libraryReturnScreen == .landing means Home; The End
    /// sets that too, and its story is over, so a new story is right there
    /// as well).
    public static func libraryTile(openedFromHome: Bool) -> StoryEntry {
        openedFromHome ? .libraryNewStoryTileOpenedFromHome : .libraryNewStoryTile
    }

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
        case .homeCreateStory, .libraryNewStoryTileOpenedFromHome:
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
