package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.ConversationTurn
import com.jessvb.tinytalk.core.Speaker
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class StoryStoreTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun store() = StoryStore(File(tmp.root, "stories"))

    private fun story(id: String, createdAt: String, status: RewriteStatus = RewriteStatus.PENDING) = LocalStory(
        id = id,
        createdAtIso = createdAt,
        turns = listOf(
            ConversationTurn(Speaker.CHILD, "a dog named \"Rex\""),
            ConversationTurn(Speaker.AGENT, "Rex ran home.", interrupted = true),
        ),
        sharedFacts = listOf("dog" to "Dogs have a great sense of smell."),
        pageCount = 5,
        title = if (status == RewriteStatus.DONE) "Rex Goes Home" else null,
        pages = if (status == RewriteStatus.DONE) listOf(LocalPage("Rex ran.", hasImage = false), LocalPage("Rex slept.")) else emptyList(),
        epilogue = if (status == RewriteStatus.DONE) "And one true thing we learned about the dog: Dogs smell well." else null,
        rewriteStatus = status,
    )

    @Test fun `save then get round-trips every field`() {
        val s = store()
        val done = story("abc123", "2026-11-04T10:00:00Z", RewriteStatus.DONE)
        s.save(done)
        assertEquals(done, s.get("abc123"))
    }

    @Test fun `get of an unknown id returns null`() {
        assertNull(store().get("nope"))
    }

    @Test fun `get refuses ids that could escape the directory`() {
        assertNull(store().get("../evil"))
        assertNull(store().get("a/b"))
    }

    @Test fun `list is newest first`() {
        val s = store()
        s.save(story("old", "2026-11-01T10:00:00Z"))
        s.save(story("new", "2026-11-04T10:00:00Z"))
        s.save(story("mid", "2026-11-02T10:00:00Z"))
        assertEquals(listOf("new", "mid", "old"), s.list().map { it.id })
    }

    @Test fun `save overwrites the same id`() {
        val s = store()
        s.save(story("x", "2026-11-04T10:00:00Z"))
        s.save(story("x", "2026-11-04T10:00:00Z", RewriteStatus.DONE))
        assertEquals(RewriteStatus.DONE, s.get("x")?.rewriteStatus)
        assertEquals(1, s.list().size)
    }

    @Test fun `a corrupt json file is skipped and the rest still list`() {
        val s = store()
        s.save(story("good", "2026-11-04T10:00:00Z"))
        File(tmp.root, "stories/bad.json").writeText("{ not json")
        assertEquals(listOf("good"), s.list().map { it.id })
        assertNull(s.get("bad"))
    }

    @Test fun `a leftover tmp file from an interrupted save is ignored`() {
        val s = store()
        s.save(story("good", "2026-11-04T10:00:00Z"))
        File(tmp.root, "stories/half.json.tmp").writeText("{\"id\":\"half\"")
        assertEquals(listOf("good"), s.list().map { it.id })
    }

    @Test fun `a save leaves no tmp file behind`() {
        val s = store()
        s.save(story("good", "2026-11-04T10:00:00Z"))
        assertTrue(File(tmp.root, "stories").listFiles()!!.none { it.name.endsWith(".tmp") })
    }
}
