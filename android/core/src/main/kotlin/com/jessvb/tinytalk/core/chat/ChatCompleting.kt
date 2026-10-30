package com.jessvb.tinytalk.core.chat

interface ChatCompleting {
    suspend fun complete(messages: List<ChatMessage>): String
}
