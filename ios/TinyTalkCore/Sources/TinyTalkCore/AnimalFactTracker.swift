import Foundation

private let weaveInTemplate =
    "The story just mentioned a %1$@. Weave this real fact about the " +
    "%1$@ naturally into what happens next, as part of the action -- " +
    "don't just state it as trivia: %2$@"

private let firstAnimalNudge =
    "No animal has been part of the story yet. Before continuing, warmly " +
    "ask the child what animal should be in the story."

/// Swift port of server/tinytalk/animal_facts.py's AnimalFactTracker --
/// per-story state, recreated fresh (via reset()) whenever a story
/// finishes. An actor because it does real awaited network fetches
/// (through `fetcher`) and must serialize concurrent access, same
/// reasoning as SessionCoordinator's own actor isolation.
public actor AnimalFactTracker {
    private let fetcher: any AnimalFactFetching
    private let cache: AnimalFactsCache
    private var facted: Set<String> = []
    private var attempted: Set<String> = []
    private var anyAnimalMentioned = false
    private var _sharedFacts: [(animal: String, fact: String)] = []

    public init(fetcher: any AnimalFactFetching, cache: AnimalFactsCache = AnimalFactsCache()) {
        self.fetcher = fetcher
        self.cache = cache
    }

    public func sharedFacts() -> [(animal: String, fact: String)] { _sharedFacts }

    public func reset() {
        facted = []
        attempted = []
        anyAnimalMentioned = false
        _sharedFacts = []
        cache.save([:])
    }

    public func recordTurn(transcript: String, stage: StoryStage) async -> String {
        if let canonical = AnimalFacts.findNewAnimal(in: transcript, excluding: Array(facted.union(attempted))) {
            anyAnimalMentioned = true
            attempted.insert(canonical)
            if let fact = await getFact(canonical) {
                facted.insert(canonical)
                _sharedFacts.append((canonical, fact))
                return String(format: weaveInTemplate, canonical, fact)
            }
            return ""
        }
        if (stage == .intro || stage == .setup) && !anyAnimalMentioned {
            return firstAnimalNudge
        }
        return ""
    }

    private func getFact(_ canonical: String) async -> String? {
        var current = cache.load()
        if let cached = current[canonical] {
            return cached.randomElement()
        }
        guard let facts = await fetcher.fetchFacts(for: canonical) else { return nil }
        current[canonical] = facts
        cache.save(current)
        return facts.randomElement()
    }
}
