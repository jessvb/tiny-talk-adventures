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

    @Test fun listeningNotInstalledBannerPointsToSettingsAndClearsWhenReady() {
        val s1 = run(StoryInput.ListeningNotInstalled)
        val b = assertBanner(s1, BannerKind.LISTENING_NOT_INSTALLED)
        assertTrue(b.showSettings)
        assertNull(StoryReducer.reduce(s1, StoryInput.ListeningReady).banner)
        // ListeningReady leaves other banners alone.
        val k = run(StoryInput.KeyProblem(KeyProblemKind.MISSING), StoryInput.ListeningReady)
        assertEquals(BannerKind.KEY_MISSING, k.banner!!.kind)
    }

    @Test fun turnSuccessDoesNotClearListeningNotInstalled() {
        val s = run(StoryInput.ListeningNotInstalled, StoryInput.TurnEnd)
        assertEquals(BannerKind.LISTENING_NOT_INSTALLED, s.banner!!.kind)
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
