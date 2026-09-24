import XCTest
@testable import TinyTalkCore

final class StoryEntryTests: XCTestCase {
    /// Library's "+" with no session keeps the plain (resume-if-pending)
    /// connect: a dropped connection mid-story can leave the child's
    /// bubbles on screen, and "+" must not wipe that story server-side.
    func testLibraryTileConnectsWhenNothingIsConnected() {
        for concluded in [false, true] {
            XCTAssertEqual(StoryEntry.libraryNewStoryTile.action(isConnected: false, liveStoryConcluded: concluded), .connect)
        }
    }

    /// Issue #69: a fresh connection is not a fresh server session -- the
    /// server keeps one SessionRunner for its lifetime, so Home mid-story
    /// -> Create a Story showed a blank screen while the server carried on
    /// with the abandoned story's arc. Home's button must also reset it.
    func testHomeCreateStoryConnectsAndStartsANewStoryWhenNothingIsConnected() {
        for concluded in [false, true] {
            XCTAssertEqual(StoryEntry.homeCreateStory.action(isConnected: false, liveStoryConcluded: concluded), .connectAndStartNewStory)
        }
    }

    /// Issue #64: The End -> Read it now -> Reading -> Library -> Home left
    /// the finished story's session connected, and "Create a Story" just
    /// navigated back into it -- old bubbles on screen, no new_story, and
    /// The End never appeared for the next story.
    func testHomeCreateStoryStartsANewStoryOnALiveSessionWhoseStoryIsOver() {
        XCTAssertEqual(StoryEntry.homeCreateStory.action(isConnected: true, liveStoryConcluded: true), .startNewStory)
    }

    /// Home is never "the way back into the story in progress" -- that's
    /// Library's "+" tile or its Back button.
    func testHomeCreateStoryStartsANewStoryEvenMidStory() {
        XCTAssertEqual(StoryEntry.homeCreateStory.action(isConnected: true, liveStoryConcluded: false), .startNewStory)
    }

    /// Library reached from Elsie's desk mid-story: "+" must return to the
    /// story in progress, not connect a second time on top of it.
    func testLibraryTileResumesTheStoryInProgress() {
        XCTAssertEqual(StoryEntry.libraryNewStoryTile.action(isConnected: true, liveStoryConcluded: false), .resumeLiveStory)
    }

    /// Same #64 trap through Library's own "+" (The End -> Read it now ->
    /// Reading -> Library -> "+"): resuming a finished story is never right.
    func testLibraryTileStartsANewStoryWhenTheLiveStoryIsOver() {
        XCTAssertEqual(StoryEntry.libraryNewStoryTile.action(isConnected: true, liveStoryConcluded: true), .startNewStory)
    }
}
