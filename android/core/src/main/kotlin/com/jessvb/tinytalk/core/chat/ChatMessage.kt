package com.jessvb.tinytalk.core.chat

/** One chat-completions message (role is "system", "user" or "assistant"). */
data class ChatMessage(val role: String, val content: String)
