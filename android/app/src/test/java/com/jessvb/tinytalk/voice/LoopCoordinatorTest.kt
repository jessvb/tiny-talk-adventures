package com.jessvb.tinytalk.voice

import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.settings.SttModeStore
import com.jessvb.tinytalk.core.voice.LoopState
import com.jessvb.tinytalk.ui.LineSpeaker
import com.jessvb.tinytalk.ui.ListeningNotice
import com.jessvb.tinytalk.ui.Screen
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import org.junit.After
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LoopCoordinatorTest {
    private val log = mutableListOf<String>()

    private inner class FakeLoop : LoopControl {
        var running = false
        var startOk = true
        var startWhileRunning = 0
        var throwOnStart = false
        var micMuted = false
        override fun setMuted(muted: Boolean) {
            log += "mute=$muted"
            micMuted = muted
        }
        override fun start(): Boolean {
            if (running) startWhileRunning++
            log += "start"
            if (throwOnStart) {
                running = true // a half-started loop, as a throwing VoiceLoop.start once could
                throw IllegalStateException("aec setEnabled failed")
            }
            running = startOk
            return startOk
        }
        override fun stop() {
            log += "stop"
            running = false
        }
        override val isActive: Boolean get() = running
    }

    private class Modes(override var mode: SttMode = SttMode.CLOUD) : SttModeStore

    private val loop = FakeLoop()
    private val modes = Modes()
    private var permission = true
    private var consent = true
    private var available = ListeningAvailability.READY

    /**
     * Worker and "main" share the test scheduler (so advanceUntilIdle drives them) but are not
     * children of the test (the command consumer never ends); cancelled after each test.
     */
    private var scope: CoroutineScope? = null

    @After fun tearDown() {
        scope?.cancel()
    }

    private fun TestScope.coordinator(provider: (suspend () -> LoopControl?)? = null): LoopCoordinator {
        val s = CoroutineScope(StandardTestDispatcher(testScheduler)).also { scope = it }
        return newCoordinator(s, provider)
    }

    private fun newCoordinator(s: CoroutineScope, provider: (suspend () -> LoopControl?)?) = LoopCoordinator(
        worker = s,
        main = s,
        loopProvider = provider ?: { loop },
        session = { log += "newStory" },
        modeStore = modes,
        listeningAvailability = { available },
        micPermission = { permission },
        consent = { consent },
    )

    /** Foreground app: Landing, then Create a Story. */
    private fun TestScope.enterStory(c: LoopCoordinator) {
        c.setForeground(true)
        c.onNav(Screen.LANDING)
        c.onNav(Screen.STORY)
        advanceUntilIdle()
    }

    @Test fun enteringStoryFromLandingStartsANewStoryThenListens() = runTest {
        val c = coordinator()
        enterStory(c)
        assertEquals(listOf("stop", "newStory", "start"), log)
        assertTrue(loop.running)
    }

    @Test fun micLossShowsAVisibleHaltAndRetryRestarts() = runTest {
        val c = coordinator()
        enterStory(c)
        loop.running = false // the loop halted itself
        c.onLoopError(VoiceLoop.MIC_UNAVAILABLE_MESSAGE)
        advanceUntilIdle()
        assertEquals(VoiceLoop.MIC_UNAVAILABLE_MESSAGE, c.story.value.micUnavailable)
        assertTrue(c.story.value.micUnavailableRetryable)
        assertEquals("stop", log.last())
        assertFalse(loop.running)

        c.retryMic()
        advanceUntilIdle()
        assertEquals("start", log.last())
        assertTrue(loop.running)
        assertNull(c.story.value.micUnavailable)
    }

    @Test fun settingsRoundTripKeepsTheStoryButLandingStartsANewOne() = runTest {
        val c = coordinator()
        enterStory(c)
        c.onTranscript("a dragon")
        c.onReply("A dragon! What colour?")
        c.onLoopState(LoopState.LISTENING)
        advanceUntilIdle()
        log.clear()

        c.onNav(Screen.SETTINGS)
        advanceUntilIdle()
        assertFalse(loop.running)
        c.onNav(Screen.STORY)
        advanceUntilIdle()
        assertEquals(listOf("stop", "start"), log) // no newStory
        assertEquals(2, c.story.value.lines.size)
        assertTrue(loop.running)

        c.onNav(Screen.LANDING)
        c.onNav(Screen.STORY)
        advanceUntilIdle()
        assertTrue(c.story.value.lines.isEmpty())
        assertEquals("newStory", log[log.lastIndex - 1])
        assertEquals("start", log.last())
    }

    @Test fun newStoryWhileSpeakingStopsResetsRestartsAndDropsOldLines() = runTest {
        val c = coordinator()
        enterStory(c)
        c.onTranscript("a cat")
        c.onReply("The cat said meow")
        c.onLoopState(LoopState.SPEAKING)
        advanceUntilIdle()
        log.clear()

        c.onReply("late line from the old story") // posted before the consumer stops the loop
        c.newStory()
        advanceUntilIdle()
        assertEquals(listOf("stop", "newStory", "start"), log)
        assertTrue(c.story.value.lines.isEmpty())

        c.onTranscript("a dog")
        c.onStoryFinished() // a fresh story's lines exist, so this one counts
        advanceUntilIdle()
        assertEquals(listOf(LineSpeaker.CHILD to "a dog"), c.story.value.lines.map { it.speaker to it.text })
    }

    @Test fun mutingKeepsTheLoopRunningAndOnlyClosesTheMic() = runTest {
        val c = coordinator()
        enterStory(c)
        log.clear()
        c.setPaused(true)
        advanceUntilIdle()
        assertEquals(listOf("mute=true"), log) // no stop: the in-flight turn must finish
        assertTrue(loop.running)
        c.setPaused(false)
        advanceUntilIdle()
        assertEquals(listOf("mute=true", "mute=false"), log)
    }

    @Test fun reenteringTheStoryUnmutes() = runTest {
        val c = coordinator()
        enterStory(c)
        c.setPaused(true)
        advanceUntilIdle()
        c.onNav(Screen.SETTINGS)
        c.onNav(Screen.STORY)
        advanceUntilIdle()
        assertFalse(loop.micMuted)
    }

    @Test fun newStoryWhileStoppedResetsWithoutStarting() = runTest {
        val c = coordinator()
        enterStory(c)
        c.setForeground(false) // backgrounded: the loop is stopped
        advanceUntilIdle()
        log.clear()
        c.newStory()
        advanceUntilIdle()
        assertEquals(listOf("stop", "newStory"), log)
        assertFalse(loop.running)
    }

    @Test fun staleStoryFinishedAfterNewStoryIsNotShown() = runTest {
        val c = coordinator()
        enterStory(c)
        c.onReply("happily ever after")
        c.newStory()
        advanceUntilIdle()
        c.onStoryFinished()
        advanceUntilIdle()
        assertFalse(c.story.value.storyFinished)
    }

    @Test fun permissionGrantedWhileAwayStartsOnForeground() = runTest {
        permission = false
        val c = coordinator()
        enterStory(c)
        assertTrue(c.story.value.micPermissionMissing)
        assertFalse(log.contains("start"))

        c.setForeground(false)
        permission = true
        c.setForeground(true)
        advanceUntilIdle()
        assertEquals("start", log.last())
        assertFalse(c.story.value.micPermissionMissing)
    }

    @Test fun permissionResultStartsTheLoop() = runTest {
        permission = false
        val c = coordinator()
        enterStory(c)
        c.onPermissionResult(true)
        advanceUntilIdle()
        assertTrue(loop.running)
    }

    @Test fun onStopStopsAndOnStartResumesOnlyOnStory() = runTest {
        val c = coordinator()
        enterStory(c)
        c.setForeground(false)
        advanceUntilIdle()
        assertFalse(loop.running)
        c.setForeground(true)
        advanceUntilIdle()
        assertTrue(loop.running)

        c.onNav(Screen.SETTINGS)
        c.setForeground(false)
        c.setForeground(true)
        advanceUntilIdle()
        assertFalse(loop.running)
        assertEquals("stop", log.last())
    }

    @Test fun rapidTogglesNeverDoubleStartOrLeaveTheMicOpen() = runTest {
        val c = coordinator()
        enterStory(c)
        repeat(5) {
            c.setPaused(true)
            c.setPaused(false)
            c.setPaused(true)
        }
        c.setForeground(false)
        c.setForeground(true)
        advanceUntilIdle()
        assertEquals(0, loop.startWhileRunning)
        assertTrue(loop.running) // muting never stops the loop; foreground toggles ended running
        assertTrue(loop.micMuted) // last request: muted
        c.setPaused(false)
        advanceUntilIdle()
        assertFalse(loop.micMuted)
        assertTrue(loop.running)
        assertEquals(0, loop.startWhileRunning)
    }

    @Test fun revokeConsentStopsTheLoopAndResetsBetterListening() = runTest {
        modes.mode = SttMode.CLOUD
        val c = coordinator()
        enterStory(c)
        assertEquals(SttMode.CLOUD, c.sttMode)

        c.revokeConsent()
        consent = false // the Navigator clears the store right after
        c.onNav(Screen.ONBOARDING)
        advanceUntilIdle()
        assertFalse(loop.running)
        assertEquals(SttMode.ON_DEVICE, modes.mode)
        assertEquals(SttMode.ON_DEVICE, c.sttMode)
    }

    @Test fun revokeConsentResetsTheModeEvenWhenNotOnStory() = runTest {
        modes.mode = SttMode.CLOUD
        val c = coordinator()
        c.onNav(Screen.SETTINGS)
        c.revokeConsent()
        assertEquals(SttMode.ON_DEVICE, modes.mode)
    }

    @Test fun clearWithQueuedCommandsNeverStartsTheLoop() = runTest {
        val gate = CompletableDeferred<LoopControl?>()
        val c = coordinator(provider = { gate.await() })
        c.setForeground(true)
        c.onNav(Screen.LANDING)
        c.onNav(Screen.STORY) // NewStory + Apply(true) queued behind the audio build
        advanceUntilIdle()
        c.clear()
        gate.complete(loop)
        advanceUntilIdle()
        assertFalse(log.contains("start"))
        assertFalse(loop.running)
    }

    @Test fun clearStopsARunningLoop() = runTest {
        val c = coordinator()
        enterStory(c)
        c.clear()
        assertFalse(loop.running)
        c.setPaused(true)
        c.setPaused(false)
        advanceUntilIdle()
        assertFalse(loop.running)
    }

    @Test fun audioThatNeverBuiltIsANonRetryableVisibleState() = runTest {
        val c = coordinator(provider = { null })
        enterStory(c)
        assertNotNull(c.story.value.micUnavailable)
        assertFalse(c.story.value.micUnavailableRetryable)
        c.retryMic()
        advanceUntilIdle()
        assertNotNull(c.story.value.micUnavailable)
        assertFalse(log.contains("start"))
    }

    @Test fun audioBuildThrowingAnErrorIsTheSameVisibleStateNotACrash() = runTest {
        // #88: an Error (not an Exception) from the audio build must not kill the consumer.
        val c = coordinator(provider = { throw ExceptionInInitializerError(IllegalStateException("x")) })
        enterStory(c)
        assertNotNull(c.story.value.micUnavailable)
        assertFalse(c.story.value.micUnavailableRetryable)
    }

    @Test fun listeningUnavailableKeepsTheLoopOffUntilAModeThatWorks() = runTest {
        modes.mode = SttMode.ON_DEVICE
        available = ListeningAvailability.FAILED
        val c = coordinator()
        enterStory(c)
        assertEquals(ListeningNotice.FAILED, c.story.value.listeningNotice)
        assertFalse(log.contains("start"))

        available = ListeningAvailability.READY
        c.setSttMode(SttMode.CLOUD)
        advanceUntilIdle()
        assertNull(c.story.value.listeningNotice)
        assertTrue(loop.running)
        assertEquals(SttMode.CLOUD, modes.mode)
    }

    @Test fun listeningStartsByItselfWhenTheModelFinishesLoadingOnTheStoryScreen() = runTest {
        modes.mode = SttMode.ON_DEVICE
        available = ListeningAvailability.LOADING
        val c = coordinator()
        enterStory(c)
        assertEquals(ListeningNotice.LOADING, c.story.value.listeningNotice)
        assertFalse(log.contains("start"))

        available = ListeningAvailability.READY
        c.onListeningAvailabilityChanged()
        advanceUntilIdle()
        assertNull(c.story.value.listeningNotice)
        assertTrue(loop.running)
        assertEquals("start", log.last())
    }

    @Test fun aFailedLoadOnTheStoryScreenStaysOffWithAVisibleNotice() = runTest {
        modes.mode = SttMode.ON_DEVICE
        available = ListeningAvailability.LOADING
        val c = coordinator()
        enterStory(c)

        available = ListeningAvailability.FAILED
        c.onListeningAvailabilityChanged()
        advanceUntilIdle()
        assertEquals(ListeningNotice.FAILED, c.story.value.listeningNotice)
        assertFalse(log.contains("start"))
        assertFalse(loop.running)
    }

    @Test fun aLoadFinishingOffTheStoryScreenIsPickedUpOnEntry() = runTest {
        modes.mode = SttMode.ON_DEVICE
        available = ListeningAvailability.LOADING
        val c = coordinator()
        c.setForeground(true)
        c.onNav(Screen.LANDING)
        available = ListeningAvailability.READY
        c.onListeningAvailabilityChanged() // not on Story: nothing starts
        advanceUntilIdle()
        assertFalse(log.contains("start"))
        c.onNav(Screen.STORY)
        advanceUntilIdle()
        assertNull(c.story.value.listeningNotice)
        assertTrue(loop.running)
    }

    @Test fun chatKeyAvailabilityDrivesTheUpFrontBanner() = runTest {
        val c = coordinator()
        enterStory(c)
        c.setChatKeyAvailable(false)
        assertNotNull(c.story.value.banner)
        c.setChatKeyAvailable(true)
        assertNull(c.story.value.banner)
    }

    @Test fun aThrowingStartIsOneVisibleRetryableErrorAndTheConsumerSurvives() = runTest {
        loop.throwOnStart = true
        val c = coordinator()
        enterStory(c)
        assertEquals(VoiceLoop.MIC_UNAVAILABLE_MESSAGE, c.story.value.micUnavailable)
        assertTrue(c.story.value.micUnavailableRetryable)
        assertFalse(loop.running) // left stopped, not half-started
        assertEquals(1, log.count { it == "start" })

        loop.throwOnStart = false
        c.retryMic()
        advanceUntilIdle()
        assertTrue(loop.running)
        assertNull(c.story.value.micUnavailable)
    }

    @Test fun sessionErrorsBecomeARetryBannerAndKeepTheLoopRunning() = runTest {
        val c = coordinator()
        enterStory(c)
        c.onLoopError("Elsie's cloud brain is having trouble -- let's try again in a moment.")
        advanceUntilIdle()
        assertNotNull(c.story.value.banner)
        assertTrue(loop.running)
        assertEquals("start", log.last())
    }
}
