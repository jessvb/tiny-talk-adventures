import Foundation

private struct AnimalRecord: Decodable {
    let characteristics: Characteristics?

    struct Characteristics: Decodable {
        let mostDistinctiveFeature: String?
        let topSpeed: String?
        let diet: String?
        let habitat: String?
        let slogan: String?
        let color: String?
        let groupBehavior: String?
        let lifespan: String?

        enum CodingKeys: String, CodingKey {
            case mostDistinctiveFeature = "most_distinctive_feature"
            case topSpeed = "top_speed"
            case diet, habitat, slogan, color
            case groupBehavior = "group_behavior"
            case lifespan
        }
    }
}

/// AnimalFactFetching backed by API Ninjas' Animals endpoint -- see
/// server/tinytalk/animal_facts.py's _fetch_facts_from_api for the
/// sibling server-side implementation this mirrors. Optional by design:
/// a nil/empty apiKey is a silent no-op, matching
/// config.ANIMAL_FACTS_API_KEY's existing "without it, lookups silently
/// no-op" behavior.
public final class AnimalFactsAPIClient: AnimalFactFetching, @unchecked Sendable {
    private static let host = "https://api.api-ninjas.com"
    private let apiKey: String?
    private let session: URLSession

    public init(apiKey: String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func fetchFacts(for canonicalName: String) async -> [String]? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "\(Self.host)/v1/animals")!
        components.queryItems = [URLQueryItem(name: "name", value: canonicalName)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let records = try JSONDecoder().decode([AnimalRecord].self, from: data)
            guard let first = records.first, let characteristics = first.characteristics else {
                return records.isEmpty ? [] : []
            }
            return AnimalFacts.extractFacts(from: AnimalRecordCharacteristics(
                mostDistinctiveFeature: characteristics.mostDistinctiveFeature,
                topSpeed: characteristics.topSpeed,
                diet: characteristics.diet,
                habitat: characteristics.habitat,
                slogan: characteristics.slogan,
                color: characteristics.color,
                groupBehavior: characteristics.groupBehavior,
                lifespan: characteristics.lifespan
            ))
        } catch {
            return nil
        }
    }
}

/// On-disk fact cache, mirroring animal_facts.py's _load_cache/_save_cache
/// -- a fetched fact is remembered so a repeated mention (in this or a
/// later demo session) never re-hits the API.
public final class AnimalFactsCache: @unchecked Sendable {
    private let path: URL
    private let lock = NSLock()

    public init(path: URL = AnimalFactsCache.defaultPath) {
        self.path = path
    }

    public static var defaultPath: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("animal_facts_cache.json")
    }

    public func load() -> [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: path) else { return [:] }
        return (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }

    public func save(_ cache: [String: [String]]) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: path)
    }
}
