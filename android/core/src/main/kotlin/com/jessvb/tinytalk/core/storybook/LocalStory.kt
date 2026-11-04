package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.ConversationTurn

enum class RewriteStatus { PENDING, DONE, FAILED }

/** One storybook page. [hasImage] is reserved for the later illustrations spec. */
data class LocalPage(val text: String, val hasImage: Boolean = false)

/**
 * A saved story: the raw transcript (kept even if the rewrite fails) plus, once the rewrite
 * is [RewriteStatus.DONE], the title, pages and epilogue. Mirrors iOS `LocalStory`.
 */
data class LocalStory(
    val id: String,
    val createdAtIso: String,
    val turns: List<ConversationTurn>,
    /** (animal, fact) pairs actually shared in this story, in order. */
    val sharedFacts: List<Pair<String, String>>,
    /** The page count the story was created with (the target, not necessarily pages.size). */
    val pageCount: Int,
    val title: String? = null,
    val pages: List<LocalPage> = emptyList(),
    val epilogue: String? = null,
    val rewriteStatus: RewriteStatus = RewriteStatus.PENDING,
)

/** What a just-finished story hands to the library: its own turns and shared facts. */
data class FinishedStory(
    val turns: List<ConversationTurn>,
    val sharedFacts: List<Pair<String, String>>,
)
