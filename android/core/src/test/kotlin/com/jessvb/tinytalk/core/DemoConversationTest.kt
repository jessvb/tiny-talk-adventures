package com.jessvb.tinytalk.core

import com.jessvb.tinytalk.core.chat.ChatMessage
import org.junit.Assert.assertEquals
import org.junit.Test

class DemoConversationTest {
    @Test fun emptyAndWhitespaceDropped() {
        val c = DemoConversation()
        c.addChild("")
        c.addChild("   \n ")
        c.addAgent("  ")
        assertEquals(0, c.fullHistory.size)
    }

    @Test fun textIsTrimmed() {
        val c = DemoConversation()
        c.addChild("  hi \n")
        assertEquals("hi", c.fullHistory[0].text)
    }

    @Test fun windowKeepsLast20FullHistoryKeepsAll() {
        val c = DemoConversation()
        for (i in 1..25) c.addChild("m$i")
        assertEquals(25, c.fullHistory.size)
        val msgs = c.toMessages("sys")
        assertEquals(21, msgs.size)
        assertEquals("m6", msgs[1].content)
        assertEquals("m25", msgs.last().content)
    }

    @Test fun rolesAndSystemFirst() {
        val c = DemoConversation()
        c.addChild("hello")
        c.addAgent("hi there")
        assertEquals(
            listOf(
                ChatMessage("system", "SYS"),
                ChatMessage("user", "hello"),
                ChatMessage("assistant", "hi there"),
            ),
            c.toMessages("SYS"),
        )
    }

    @Test fun interruptedAgentGetsMarker() {
        val c = DemoConversation()
        c.addAgent("Once upon", interrupted = true)
        assertEquals("Once upon [interrupted by the child]", c.toMessages("s")[1].content)
        assertEquals(true, c.fullHistory[0].interrupted)
        assertEquals(Speaker.AGENT, c.fullHistory[0].speaker)
    }

    @Test fun toMessagesDoesNotMutateHistory() {
        val c = DemoConversation()
        c.addAgent("x", interrupted = true)
        c.toMessages("s"); c.toMessages("s")
        assertEquals("x", c.fullHistory[0].text)
        assertEquals("x [interrupted by the child]", c.toMessages("s")[1].content)
    }
}
