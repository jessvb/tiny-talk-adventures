package com.jessvb.tinytalk.core.facts

import com.jessvb.tinytalk.core.StoryStage
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

private class FakeFetcher(var result: List<String>? = listOf("it lives in forests")) : AnimalFactFetching {
    val calls = mutableListOf<String>()
    override suspend fun fetchFacts(canonical: String): List<String>? {
        calls.add(canonical)
        return result
    }
}

class AnimalFactTrackerTest {
    @get:Rule val tmp = TemporaryFolder()

    private val weave = "The story just mentioned a fox. Weave this real fact about the " +
        "fox naturally into what happens next, as part of the action -- " +
        "don't just state it as trivia: it lives in forests"
    private val nudge = "No animal has been part of the story yet. Before continuing, warmly " +
        "ask the child what animal should be in the story."

    private fun cache() = AnimalFactsCache(File(tmp.root, "c.json"))

    @Test fun firstMentionReturnsWeaveIn() = runBlocking {
        val f = FakeFetcher()
        val t = AnimalFactTracker(f, cache())
        assertEquals(weave, t.recordTurn("the fox ran", StoryStage.RISING_ACTION))
        assertEquals(listOf("fox" to "it lives in forests"), t.sharedFacts())
    }

    @Test fun secondMentionOfSameAnimalIsEmpty() = runBlocking {
        val f = FakeFetcher()
        val t = AnimalFactTracker(f, cache())
        t.recordTurn("the fox ran", StoryStage.SETUP)
        assertEquals("", t.recordTurn("the fox jumped", StoryStage.SETUP))
        assertEquals(1, f.calls.size)
    }

    @Test fun nudgeOnlyInIntroOrSetupBeforeAnyAnimal() = runBlocking {
        val t = AnimalFactTracker(FakeFetcher(), cache())
        assertEquals(nudge, t.recordTurn("hello", StoryStage.INTRO))
        assertEquals(nudge, t.recordTurn("hello", StoryStage.SETUP))
        assertEquals("", t.recordTurn("hello", StoryStage.RISING_ACTION))
        assertEquals("", t.recordTurn("hello", StoryStage.DONE))
    }

    @Test fun noNudgeOnceAnAnimalWasMentioned() = runBlocking {
        val t = AnimalFactTracker(FakeFetcher(), cache())
        t.recordTurn("a fox", StoryStage.INTRO)
        assertEquals("", t.recordTurn("hello", StoryStage.SETUP))
    }

    @Test fun failedFetchReturnsEmptyAndIsNotRetried() = runBlocking {
        val f = FakeFetcher(null)
        val t = AnimalFactTracker(f, cache())
        assertEquals("", t.recordTurn("the fox ran", StoryStage.RISING_ACTION))
        assertEquals("", t.recordTurn("the fox ran again", StoryStage.RISING_ACTION))
        assertEquals(1, f.calls.size)
        assertEquals(emptyList<Pair<String, String>>(), t.sharedFacts())
        // An animal was mentioned, so no nudge afterwards either.
        assertEquals("", t.recordTurn("hello", StoryStage.INTRO))
    }

    @Test fun cacheHitSkipsFetcher() = runBlocking {
        val c = cache()
        c.save(mapOf("fox" to listOf("it lives in forests")))
        val f = FakeFetcher()
        val t = AnimalFactTracker(f, c)
        assertEquals(weave, t.recordTurn("the fox ran", StoryStage.SETUP))
        assertEquals(0, f.calls.size)
    }

    @Test fun successfulFetchIsCached() = runBlocking {
        val c = cache()
        AnimalFactTracker(FakeFetcher(), c).recordTurn("the fox ran", StoryStage.SETUP)
        assertEquals(mapOf("fox" to listOf("it lives in forests")), c.load())
    }

    @Test fun resetClearsState() = runBlocking {
        val f = FakeFetcher()
        val t = AnimalFactTracker(f, cache())
        t.recordTurn("the fox ran", StoryStage.SETUP)
        t.reset()
        assertEquals(emptyList<Pair<String, String>>(), t.sharedFacts())
        assertEquals(nudge, t.recordTurn("hello", StoryStage.INTRO))
        assertEquals(weave, t.recordTurn("the fox again", StoryStage.INTRO)) // cache hit, fresh state
    }

    @Test fun picksFromCachedFactsWithInjectedRandom() = runBlocking {
        val c = cache()
        c.save(mapOf("fox" to listOf("a", "b", "c")))
        val t = AnimalFactTracker(FakeFetcher(), c, random = kotlin.random.Random(1))
        val expected = listOf("a", "b", "c").random(kotlin.random.Random(1))
        assertEquals(listOf("fox" to expected), run { t.recordTurn("fox", StoryStage.SETUP); t.sharedFacts() })
    }
}
