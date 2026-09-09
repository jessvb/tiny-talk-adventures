import Foundation

private struct GroqChatRequest: Encodable {
    let model: String
    let messages: [[String: String]]
    let stream: Bool
}

private struct GroqChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String }
        let message: Message
    }
    let choices: [Choice]
}

/// ChatCompleting backed by Groq's hosted, OpenAI-compatible chat
/// completions API -- see server/tinytalk/llm_groq.py for the sibling
/// server-side implementation this mirrors (non-streaming here; see
/// this file's task notes for why).
public final class GroqChatClient: ChatCompleting, @unchecked Sendable {
    private let apiKey: String
    private let model: String
    private let host: String
    private let session: URLSession

    /// Model default matches config.py's GROQ_MODEL. Groq's free-tier
    /// model lineup changes over time -- verify this is still current at
    /// https://console.groq.com before relying on it, same caveat as
    /// that file's own comment.
    public init(
        apiKey: String,
        model: String = "llama-3.1-8b-instant",
        host: String = "https://api.groq.com",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.host = host
        self.session = session
    }

    public func complete(messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: URL(string: "\(host)/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GroqChatRequest(model: model, messages: messages, stream: false)
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DemoConnectionError.groqError("Groq chat completion returned an error: \(detail)")
        }
        let decoded = try JSONDecoder().decode(GroqChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw DemoConnectionError.groqError("Groq chat completion returned no choices")
        }
        return content
    }
}
