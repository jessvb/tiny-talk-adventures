import Foundation

/// Protocol seams DemoConnection depends on, mirroring Interfaces.swift's
/// existing role for SessionCoordinator -- so it can be tested with
/// fakes, no real network calls.
public protocol ChatCompleting: Sendable {
    func complete(messages: [[String: String]]) async throws -> String
}

public protocol SpeechTranscribing: Sendable {
    func transcribe(_ pcm: Data) async throws -> String
}

public protocol SpeechSynthesizing: Sendable {
    func synthesize(_ text: String) -> AsyncStream<Data>
}

public protocol AnimalFactFetching: Sendable {
    func fetchFacts(for canonicalName: String) async -> [String]?
}

public enum DemoConnectionError: Error, Sendable, Equatable {
    case groqError(String)
}
