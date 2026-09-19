import Foundation

/// One line of the on-screen story-so-far, built entirely client-side from
/// AppModel's own polled lastTranscript/lastReply -- SessionCoordinator only
/// ever exposes the CURRENT turn's latest transcript/reply (see its doc
/// comments), not a running history, so there is nothing server-side to
/// read this from. Deliberately bounded by the same disconnect/new-story
/// resets that already clear debugLog, rather than persisted anywhere --
/// this is a presentation convenience, not a second copy of the story
/// (server/tinytalk/story_store.py's turn list remains the one real record).
public struct StoryTurn: Identifiable, Equatable, Sendable {
    public enum Speaker: Equatable, Sendable { case child, elsie }

    public let id = UUID()
    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// The story screen's running chat history (StoryTurn's doc comment) plus
/// the bookkeeping that keeps it free of duplicates -- pulled out of
/// AppModel's poll loop so that bookkeeping can be unit-tested.
public struct TurnHistory: Equatable, Sendable {
    public private(set) var turns: [StoryTurn] = []
    /// Which turn_id's transcript/reply has already been appended to
    /// `turns` -- without this, every 100ms poll tick would re-append the
    /// same still-current turn's text again. Not a perfect boundary (a poll
    /// tick can in principle land just as the next turn's id replaces this
    /// one before this turn's own reply was polled), but this is a
    /// presentation nicety, not the source of truth -- see StoryTurn's doc
    /// comment.
    private var lastAppendedTranscriptTurnId: Int?
    private var lastAppendedReplyTurnId: Int?

    public init() {}

    /// Feed in the coordinator's latest transcript/reply and the turn_ids
    /// that TEXT ITSELF belongs to (SessionCoordinator.lastTranscriptTurnId/
    /// lastReplyTurnId) -- NOT activeTurnId (the CURRENT/latest turn), which
    /// can already have advanced to a new turn the instant the child starts
    /// talking again, before that new turn's own transcript/reply have
    /// arrived. Keying off activeTurnId was confirmed on real hardware to
    /// duplicate the previous bubble the moment the child spoke again, and
    /// then silently skip the real new turn once it did arrive (already
    /// marked "seen" under the wrong id) -- the UI appeared backed up by one
    /// turn. Keyed off turn_id rather than text equality so a repeated
    /// phrase (e.g. the child saying "hi" in two different turns) still gets
    /// its own bubble. Appends at most once per turn_id per speaker, so it is
    /// safe to call on every poll tick.
    public mutating func observe(transcript: String, transcriptTurnId: Int?, reply: String, replyTurnId: Int?) {
        if !transcript.isEmpty, let transcriptTurnId, transcriptTurnId != lastAppendedTranscriptTurnId {
            turns.append(StoryTurn(speaker: .child, text: transcript))
            lastAppendedTranscriptTurnId = transcriptTurnId
        }
        if !reply.isEmpty, let replyTurnId, replyTurnId != lastAppendedReplyTurnId {
            turns.append(StoryTurn(speaker: .elsie, text: reply))
            lastAppendedReplyTurnId = replyTurnId
        }
    }

    /// Forgets everything -- a user-initiated exit (Home, New Story), where
    /// the next story must start from a blank screen.
    public mutating func clear() {
        turns = []
        lastAppendedTranscriptTurnId = nil
        lastAppendedReplyTurnId = nil
    }
}
