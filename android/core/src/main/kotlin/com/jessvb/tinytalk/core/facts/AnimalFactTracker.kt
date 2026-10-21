package com.jessvb.tinytalk.core.facts

import com.jessvb.tinytalk.core.StoryStage
import kotlin.random.Random
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

private fun weaveInTemplate(animal: String, fact: String) =
    "The story just mentioned a $animal. Weave this real fact about the " +
        "$animal naturally into what happens next, as part of the action -- " +
        "don't just state it as trivia: $fact"

private const val FIRST_ANIMAL_NUDGE =
    "No animal has been part of the story yet. Before continuing, warmly " +
        "ask the child what animal should be in the story."

/**
 * Port of AnimalFactTracker.swift: per-story state, cleared by [reset] when a
 * story finishes. All access is serialized with a [Mutex] because lookups
 * suspend on network fetches.
 */
class AnimalFactTracker(
    private val fetcher: AnimalFactFetching,
    private val cache: AnimalFactsCache,
    private val random: Random = Random.Default,
) {
    private val mutex = Mutex()
    private val facted = mutableSetOf<String>()
    private val attempted = mutableSetOf<String>()
    private var anyAnimalMentioned = false
    private val shared = mutableListOf<Pair<String, String>>()

    suspend fun sharedFacts(): List<Pair<String, String>> = mutex.withLock { shared.toList() }

    suspend fun reset() = mutex.withLock {
        facted.clear()
        attempted.clear()
        anyAnimalMentioned = false
        shared.clear()
    }

    suspend fun recordTurn(transcript: String, stage: StoryStage): String = mutex.withLock {
        val canonical = AnimalFacts.findNewAnimal(transcript, facted + attempted)
        if (canonical != null) {
            anyAnimalMentioned = true
            attempted.add(canonical)
            val fact = getFact(canonical)
            if (fact != null) {
                facted.add(canonical)
                shared.add(canonical to fact)
                return@withLock weaveInTemplate(canonical, fact)
            }
            return@withLock ""
        }
        if ((stage == StoryStage.INTRO || stage == StoryStage.SETUP) && !anyAnimalMentioned) {
            return@withLock FIRST_ANIMAL_NUDGE
        }
        ""
    }

    private suspend fun getFact(canonical: String): String? {
        cache.load()[canonical]?.let { return it.randomOrNull(random) }
        val facts = fetcher.fetchFacts(canonical) ?: return null
        cache.save(cache.load() + (canonical to facts))
        return facts.randomOrNull(random)
    }
}
