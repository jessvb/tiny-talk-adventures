package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.ConversationTurn
import com.jessvb.tinytalk.core.Speaker
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File

/**
 * One JSON file per story in [dir]. Saves are atomic (write `<id>.json.tmp`, then rename), so a
 * crash mid-save leaves the previous version intact; unreadable files are skipped, never thrown.
 * Thread-safe.
 */
class StoryStore(private val dir: File) {
    private val lock = Any()

    fun save(story: LocalStory) {
        require(validId(story.id)) { "bad story id" }
        synchronized(lock) {
            dir.mkdirs()
            val target = File(dir, "${story.id}.json")
            val tmp = File(dir, "${story.id}.json.tmp")
            tmp.writeText(json.encodeToString(StoryDto.serializer(), StoryDto.from(story)))
            if (!tmp.renameTo(target)) {
                // Some filesystems refuse to rename over an existing file.
                target.delete()
                if (!tmp.renameTo(target)) {
                    tmp.delete()
                    throw java.io.IOException("could not save story")
                }
            }
        }
    }

    fun get(id: String): LocalStory? {
        if (!validId(id)) return null
        return synchronized(lock) { read(File(dir, "$id.json")) }
    }

    /** Newest first by creation time; files that cannot be read are skipped. */
    fun list(): List<LocalStory> = synchronized(lock) {
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".json") } ?: return emptyList()
        files.mapNotNull { read(it) }.sortedByDescending { it.createdAtIso }
    }

    private fun read(file: File): LocalStory? = try {
        if (!file.isFile) null else json.decodeFromString(StoryDto.serializer(), file.readText()).toStory()
    } catch (t: Exception) {
        null // corrupt or half-written: skip, never crash the Library
    }

    private fun validId(id: String) = id.isNotEmpty() && id.all { it.isLetterOrDigit() || it == '-' || it == '_' }

    @Serializable
    private data class TurnDto(val speaker: String, val text: String, val interrupted: Boolean = false)

    @Serializable
    private data class FactDto(val animal: String, val fact: String)

    @Serializable
    private data class PageDto(val text: String, val hasImage: Boolean = false)

    @Serializable
    private data class StoryDto(
        val id: String,
        val createdAt: String,
        val turns: List<TurnDto>,
        val sharedFacts: List<FactDto>,
        val pageCount: Int,
        val title: String? = null,
        val pages: List<PageDto> = emptyList(),
        val epilogue: String? = null,
        val rewriteStatus: String = RewriteStatus.PENDING.name,
    ) {
        fun toStory() = LocalStory(
            id = id,
            createdAtIso = createdAt,
            turns = turns.map { ConversationTurn(Speaker.valueOf(it.speaker), it.text, it.interrupted) },
            sharedFacts = sharedFacts.map { it.animal to it.fact },
            pageCount = pageCount,
            title = title,
            pages = pages.map { LocalPage(it.text, it.hasImage) },
            epilogue = epilogue,
            rewriteStatus = RewriteStatus.valueOf(rewriteStatus),
        )

        companion object {
            fun from(s: LocalStory) = StoryDto(
                id = s.id,
                createdAt = s.createdAtIso,
                turns = s.turns.map { TurnDto(it.speaker.name, it.text, it.interrupted) },
                sharedFacts = s.sharedFacts.map { FactDto(it.first, it.second) },
                pageCount = s.pageCount,
                title = s.title,
                pages = s.pages.map { PageDto(it.text, it.hasImage) },
                epilogue = s.epilogue,
                rewriteStatus = s.rewriteStatus.name,
            )
        }
    }

    private companion object {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}
