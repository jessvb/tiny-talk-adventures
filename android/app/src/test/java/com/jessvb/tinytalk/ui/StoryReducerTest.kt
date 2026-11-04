package com.jessvb.tinytalk.ui

import com.jessvb.tinytalk.core.session.KeyProblemKind
import com.jessvb.tinytalk.core.voice.LoopState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StoryReducerTest {
    private fun run(vararg inputs: StoryInput, from: StoryUiState = StoryUiState()) =
        inputs.fold(from) { s, i -> StoryReducer.reduce(s, i) }

    @Test fun startsEmptyAndIdle() {
        val s = StoryUiState()
        assertEquals(LoopState.IDLE, s.loopState)
        assertTrue(s.lines.isEmpty())
        assertNull(s.banner)
        assertFalse(s.micPermissionMissing)
        assertNull(s.micUnavailable)
    }

    @Test fun rateLimitedSetsASettingsBannerThatSaysItMayPass() {
        val s = run(StoryInput.KeyProblem(KeyProblemKind.RATE_LIMITED))
        val b = assertBanner(s, BannerKind.KEY_RATE_LIMITED)
        assertTrue(b.showSettings)
        assertTrue(b.message.contains("Settings"))
        assertTrue(b.message.contains("may pass"))
    }

    @Test fun everyKeyProblemPointsTheParentToSettings() {
        for (kind in KeyProblemKind.entries) {
            val b = run(StoryInput.KeyProblem(kind)).banner ?: throw AssertionError("no banner for $kind")
            assertTrue(kind.name, b.showSettings)
            assertTrue(kind.name, b.message.contains("grown-up"))
            assertTrue(kind.name, b.message.contains("Settings"))
        }
        assertEquals(BannerKind.KEY_MISSING, run(StoryInput.KeyProblem(KeyProblemKind.MISSING)).banner!!.kind)
        assertEquals(BannerKind.KEY_REJECTED, run(StoryInput.KeyProblem(KeyProblemKind.REJECTED)).banner!!.kind)
    }

    @Test fun nextSuccessfulTurnClearsAKeyBanner() {
        val s = run(StoryInput.KeyProblem(KeyProblemKind.RATE_LIMITED), StoryInput.TurnEnd)
        assertNull(s.banner)
    }

    @Test fun aReplyAlsoCountsAsSuccess() {
        val s = run(StoryInput.KeyProblem(KeyProblemKind.MISSING), StoryInput.Reply("Once upon a time"))
        assertNull(s.banner)
    }

    @Test fun errorSetsARetryBannerAndSuccessClearsIt() {
        val s1 = run(StoryInput.Error("Elsie's cloud brain is having trouble -- let's try again in a moment."))
        val b = assertBanner(s1, BannerKind.RETRY)
        assertFalse(b.showSettings)
        assertEquals("Elsie's cloud brain is having trouble -- let's try again in a moment.", b.message)
        assertNull(StoryReducer.reduce(s1, StoryInput.TurnEnd).banner)
    }

    @Test fun transcriptAndReplyAppendLinesInOrder() {
        val s = run(
            StoryInput.Transcript("a dragon"),
            StoryInput.Reply("A dragon! What colour is it?"),
            StoryInput.Transcript("blue"),
            StoryInput.Reply("A blue dragon flew up."),
        )
        assertEquals(
            listOf(
                LineSpeaker.CHILD to "a dragon",
                LineSpeaker.ELSIE to "A dragon! What colour is it?",
                LineSpeaker.CHILD to "blue",
                LineSpeaker.ELSIE to "A blue dragon flew up.",
            ),
            s.lines.map { it.speaker to it.text },
        )
        assertEquals(s.lines.size, s.lines.map { it.id }.toSet().size)
    }

    @Test fun blankTranscriptsAddNoChildLine() {
        val s = run(StoryInput.Transcript(""), StoryInput.Transcript("   "), StoryInput.Reply("Shall we go on?"))
        assertEquals(listOf(LineSpeaker.ELSIE), s.lines.map { it.speaker })
    }

    @Test fun consecutiveDuplicatesAreKept() {
        val s = run(StoryInput.Transcript("yes"), StoryInput.Transcript("yes"))
        assertEquals(listOf("yes", "yes"), s.lines.map { it.text })
    }

    @Test fun newStoryClearsTheTranscriptButKeepsIdsUnique() {
        val s1 = run(StoryInput.Transcript("a cat"), StoryInput.Reply("Meow"), StoryInput.StoryFinished)
        val s2 = StoryReducer.reduce(s1, StoryInput.NewStory)
        assertTrue(s2.lines.isEmpty())
        assertFalse(s2.storyFinished)
        val s3 = StoryReducer.reduce(s2, StoryInput.Transcript("a dog"))
        assertTrue(s1.lines.none { it.id == s3.lines.single().id })
    }

    @Test fun storyFinishedShowsTheEndUntilTheChildTalksAgain() {
        val s1 = run(StoryInput.Reply("And they lived happily ever after."), StoryInput.StoryFinished)
        assertTrue(s1.storyFinished)
        assertFalse(StoryReducer.reduce(s1, StoryInput.Transcript("again")).storyFinished)
    }

    @Test fun loopStateIsTracked() {
        assertEquals(LoopState.THINKING, run(StoryInput.LoopStateChanged(LoopState.THINKING)).loopState)
    }

    @Test fun micUnavailableIsVisibleUntilTheLoopRunsAgain() {
        val s1 = run(StoryInput.LoopStateChanged(LoopState.LISTENING), StoryInput.MicUnavailable("Microphone unavailable."))
        assertEquals("Microphone unavailable.", s1.micUnavailable)
        assertEquals(LoopState.IDLE, s1.loopState)
        assertNull(StoryReducer.reduce(s1, StoryInput.LoopStateChanged(LoopState.LISTENING)).micUnavailable)
        assertNull(StoryReducer.reduce(s1, StoryInput.MicRetry).micUnavailable)
        // IDLE alone does not clear it (the loop reports IDLE as it halts).
        assertNotNull(StoryReducer.reduce(s1, StoryInput.LoopStateChanged(LoopState.IDLE)).micUnavailable)
    }

    @Test fun permissionMissingAndGranted() {
        val s1 = run(StoryInput.PermissionMissing)
        assertTrue(s1.micPermissionMissing)
        assertFalse(StoryReducer.reduce(s1, StoryInput.PermissionGranted).micPermissionMissing)
    }

    @Test fun listeningUnavailableIsItsOwnStateAndClearsWhenReady() {
        val s1 = run(StoryInput.ListeningUnavailable(ListeningNotice.LOADING))
        assertEquals(ListeningNotice.LOADING, s1.listeningNotice)
        assertNull(s1.banner) // a separate notice, so it never hides a key banner
        assertEquals("Elsie is getting ready", StoryReducer.stateLabel(s1))
        assertNull(StoryReducer.reduce(s1, StoryInput.ListeningReady).listeningNotice)
        // ListeningReady leaves banners alone.
        val k = run(StoryInput.KeyProblem(KeyProblemKind.MISSING), StoryInput.ListeningReady)
        assertEquals(BannerKind.KEY_MISSING, k.banner!!.kind)
    }

    @Test fun listeningLoadFailureHasAVisibleParentMessage() {
        val s = run(StoryInput.ListeningUnavailable(ListeningNotice.LOADING), StoryInput.ListeningUnavailable(ListeningNotice.FAILED))
        assertEquals(ListeningNotice.FAILED, s.listeningNotice)
        assertEquals("Elsie can't listen", StoryReducer.stateLabel(s))
        assertTrue(StoryReducer.listeningMessage(ListeningNotice.FAILED).contains("Close the app"))
        assertTrue(StoryReducer.listeningMessage(ListeningNotice.LOADING).contains("getting her ears ready"))
    }

    @Test fun listeningUnavailableAndKeyMissingShowTogether() {
        val s = run(StoryInput.ListeningUnavailable(ListeningNotice.FAILED), StoryInput.ChatKeyMissing)
        assertEquals(ListeningNotice.FAILED, s.listeningNotice)
        assertEquals(BannerKind.KEY_MISSING, s.banner!!.kind)
    }

    @Test fun missingChatKeyShowsASettingsBannerBeforeAnyoneSpeaks() {
        val s = run(StoryInput.ChatKeyMissing)
        val b = assertBanner(s, BannerKind.KEY_MISSING)
        assertTrue(b.showSettings)
        assertEquals(StoryReducer.KEY_NEEDED_MESSAGE, b.message)
        assertTrue(b.message.contains("grown-up") && b.message.contains("Settings"))
    }

    @Test fun chatKeyPresentClearsOnlyAKeyMissingBanner() {
        assertNull(run(StoryInput.ChatKeyMissing, StoryInput.ChatKeyPresent).banner)
        assertNull(run(StoryInput.KeyProblem(KeyProblemKind.MISSING), StoryInput.ChatKeyPresent).banner)
        val r = run(StoryInput.KeyProblem(KeyProblemKind.RATE_LIMITED), StoryInput.ChatKeyPresent)
        assertEquals(BannerKind.KEY_RATE_LIMITED, r.banner!!.kind)
        val e = run(StoryInput.Error("oops"), StoryInput.ChatKeyPresent)
        assertEquals(BannerKind.RETRY, e.banner!!.kind)
    }

    @Test fun staleStoryFinishedOnAnEmptyTranscriptIsIgnored() {
        val s = run(StoryInput.Reply("The end."), StoryInput.NewStory, StoryInput.StoryFinished)
        assertFalse(s.storyFinished)
    }

    @Test fun micUnavailableCanBeNonRetryable() {
        val s = run(StoryInput.MicUnavailable("Close the app.", canRetry = false))
        assertEquals("Close the app.", s.micUnavailable)
        assertFalse(s.micUnavailableRetryable)
        assertTrue(run(StoryInput.MicUnavailable("x")).micUnavailableRetryable)
    }

    @Test fun mutedMicLabelAndDescriptionsAreAccurateAndNeverSayPause() {
        val idle = StoryUiState(loopState = LoopState.LISTENING)
        assertEquals("Mic is off", StoryReducer.displayLabel(idle, muted = true))
        assertEquals("Elsie is listening", StoryReducer.displayLabel(idle, muted = false))
        // A real problem keeps its own, more useful label even while muted.
        val failed = StoryUiState(listeningNotice = ListeningNotice.FAILED)
        assertEquals("Elsie can't listen", StoryReducer.displayLabel(failed, muted = true))
        assertEquals("Mute microphone", StoryReducer.micButtonDescription(muted = false))
        assertEquals("Unmute microphone", StoryReducer.micButtonDescription(muted = true))
        for (text in listOf(
            StoryReducer.displayLabel(idle, true), StoryReducer.micButtonDescription(true),
            StoryReducer.micButtonDescription(false),
        )) {
            assertFalse(text, text.contains("pause", ignoreCase = true))
        }
    }

    @Test fun stateLabelsMirrorIos() {
        assertEquals("Ready when you are", StoryReducer.stateLabel(StoryUiState()))
        assertEquals("Elsie is listening", StoryReducer.stateLabel(StoryUiState(loopState = LoopState.LISTENING)))
        assertEquals("Elsie is thinking…", StoryReducer.stateLabel(StoryUiState(loopState = LoopState.THINKING)))
        assertEquals("Elsie is talking", StoryReducer.stateLabel(StoryUiState(loopState = LoopState.SPEAKING)))
        assertEquals("Mic is off", StoryReducer.stateLabel(StoryUiState(micPermissionMissing = true)))
        assertEquals("Mic is off", StoryReducer.stateLabel(StoryUiState(micUnavailable = "x")))
    }

    private fun assertBanner(s: StoryUiState, kind: BannerKind): Banner {
        val b = s.banner ?: throw AssertionError("expected a $kind banner, got none")
        assertEquals(kind, b.kind)
        return b
    }
}
