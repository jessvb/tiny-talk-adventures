package com.jessvb.tinytalk.core.storybook

import com.jessvb.tinytalk.core.rethrowIfFatal
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** What the Library shows for one story. */
data class StorySummary(
    val id: String,
    val createdAtIso: String,
    val title: String?,
    val pageCount: Int,
    val status: RewriteStatus,
)

/**
 * The phone's own library: saves a finished story's transcript at once, then rewrites it into a
 * storybook in the background, ONE build at a time (a mutex), so two quick stories never overlap
 * or overwrite each other. A failed build leaves the transcript saved with status FAILED.
 * Port of the iOS DemoStoryLibrary (without sync, which Android has no home server for).
 *
 * [begin], [detail] and [requeuePending] may be called from any thread.
 */
class StoryLibrary(
    private val store: StoryStore,
    private val writer: StorybookWriter,
    private val scope: CoroutineScope,
    private val newId: () -> String,
    private val now: () -> String,
) {
    private val buildMutex = Mutex()
    private val stateLock = Any()
    private val queued = mutableSetOf<String>() // ids with a build launched and not yet finished

    private val _summaries = MutableStateFlow(readSummaries())
    val summaries: StateFlow<List<StorySummary>> = _summaries.asStateFlow()

    private val _latestStatus = MutableStateFlow<Pair<String, RewriteStatus>?>(null)

    /** Id and status of the most recently begun story (The End watches this). */
    val latestStatus: StateFlow<Pair<String, RewriteStatus>?> = _latestStatus.asStateFlow()

    /** Saves [story] as PENDING (before any network call), queues its build, returns its id. */
    fun begin(story: FinishedStory, pageCount: Int): String {
        val id = newId()
        store.save(
            LocalStory(
                id = id,
                createdAtIso = now(),
                turns = story.turns,
                sharedFacts = story.sharedFacts,
                pageCount = pageCount,
            ),
        )
        _latestStatus.value = id to RewriteStatus.PENDING
        refresh()
        launchBuild(id)
        return id
    }

    fun detail(id: String): LocalStory? = store.get(id)

    /** App start: stories left PENDING (the app was killed mid-rewrite) get built again. */
    fun requeuePending() {
        store.list().filter { it.rewriteStatus == RewriteStatus.PENDING }.forEach { launchBuild(it.id) }
    }

    private fun launchBuild(id: String) {
        val first = synchronized(stateLock) { queued.add(id) }
        if (!first) return
        scope.launch {
            try {
                buildMutex.withLock { build(id) }
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                t.rethrowIfFatal()
                setStatus(id, RewriteStatus.FAILED)
            } finally {
                synchronized(stateLock) { queued.remove(id) }
            }
        }
    }

    private suspend fun build(id: String) {
        val story = store.get(id) ?: return
        if (story.rewriteStatus != RewriteStatus.PENDING) return // already built (e.g. requeued twice)
        val written = writer.write(story.turns, story.sharedFacts, story.pageCount)
        val result = if (written == null) {
            story.copy(rewriteStatus = RewriteStatus.FAILED)
        } else {
            story.copy(
                title = written.title,
                pages = written.pages.map { LocalPage(it) },
                epilogue = written.epilogue,
                rewriteStatus = RewriteStatus.DONE,
            )
        }
        store.save(result)
        publish(id, result.rewriteStatus)
    }

    private fun setStatus(id: String, status: RewriteStatus) {
        val story = store.get(id) ?: return
        store.save(story.copy(rewriteStatus = status))
        publish(id, status)
    }

    private fun publish(id: String, status: RewriteStatus) {
        if (_latestStatus.value?.first == id) _latestStatus.value = id to status
        refresh()
    }

    private fun refresh() {
        _summaries.value = readSummaries()
    }

    private fun readSummaries(): List<StorySummary> = store.list().map {
        // A written story reports the pages it really has; until then, the target.
        StorySummary(it.id, it.createdAtIso, it.title, if (it.pages.isEmpty()) it.pageCount else it.pages.size, it.rewriteStatus)
    }
}
