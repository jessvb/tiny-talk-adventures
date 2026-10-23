package com.jessvb.tinytalk.core

import com.jessvb.tinytalk.core.chat.ChatMessage

enum class Speaker { CHILD, AGENT }

data class ConversationTurn(
    val speaker: Speaker,
    val text: String,
    val interrupted: Boolean = false,
)

/** Kotlin port of DemoConversation.swift. Thread-safe. */
class DemoConversation(private val maxTurns: Int = 20) {
    private val lock = Any()
    private val windowed = mutableListOf<ConversationTurn>()
    private val history = mutableListOf<ConversationTurn>()

    val fullHistory: List<ConversationTurn>
        get() = synchronized(lock) { history.toList() }

    fun addChild(text: String) = add(ConversationTurn(Speaker.CHILD, text.trim()))

    fun addAgent(text: String, interrupted: Boolean = false) =
        add(ConversationTurn(Speaker.AGENT, text.trim(), interrupted))

    private fun add(turn: ConversationTurn) {
        if (turn.text.isEmpty()) return
        synchronized(lock) {
            windowed.add(turn)
            while (windowed.size > maxTurns) windowed.removeAt(0)
            history.add(turn)
        }
    }

    fun toMessages(systemPrompt: String): List<ChatMessage> = synchronized(lock) {
        buildList {
            add(ChatMessage("system", systemPrompt))
            for (turn in windowed) {
                val content = if (turn.interrupted) "${turn.text} $INTERRUPTED_MARKER" else turn.text
                add(ChatMessage(if (turn.speaker == Speaker.CHILD) "user" else "assistant", content))
            }
        }
    }

    companion object {
        const val INTERRUPTED_MARKER = "[interrupted by the child]"
    }
}
