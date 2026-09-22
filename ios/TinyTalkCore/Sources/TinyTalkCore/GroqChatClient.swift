import Foundation

private struct GroqChatRequest: Encodable {
    let model: String
    let messages: [[String: String]]
    let stream: Bool
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream
        case reasoningEffort = "reasoning_effort"
    }

    // encodeIfPresent so a nil reasoningEffort omits the key entirely,
    // rather than encoding an explicit `"reasoning_effort": null` --
    // existing callers (the live conversation, the storybook rewrite)
    // must see byte-identical request bodies to before this field existed.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
    }
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
    private let reasoningEffort: String?
    private let session: URLSession

    /// Model default matches config.py's GROQ_MODEL. Groq's free-tier
    /// model lineup changes over time -- verify this is still current at
    /// https://console.groq.com before relying on it, same caveat as
    /// that file's own comment. llama-3.1-8b-instant was shut down
    /// 2026-08-16; Groq's own deprecation notice
    /// (console.groq.com/docs/deprecations) names openai/gpt-oss-20b as
    /// its replacement -- confirmed via an on-device test hitting
    /// "model not found" on the old id.
    ///
    /// - Parameter reasoningEffort: openai/gpt-oss-20b (and -120b) is a
    ///   reasoning model that, per Groq's own docs (console.groq.com/docs/
    ///   reasoning), spends completion tokens on hidden chain-of-thought
    ///   BEFORE emitting the visible reply -- at the default "medium"
    ///   effort, a moderately complex prompt can exhaust the whole token
    ///   budget on that hidden reasoning and return content: "" with
    ///   finish_reason: "length", confirmed on-device 2026-09-22
    ///   (IllustrationPass's scene prompt, after being asked to match an
    ///   earlier page's description, came back empty on 2 of 3 pages).
    ///   nil (the default) omits the parameter, so Groq's own default
    ///   applies -- unchanged behaviour for the live conversation and the
    ///   storybook rewrite, which haven't shown this failure.
    public init(
        apiKey: String,
        model: String = "openai/gpt-oss-20b",
        host: String = "https://api.groq.com",
        reasoningEffort: String? = nil,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.host = host
        self.reasoningEffort = reasoningEffort
        self.session = session
    }

    public func complete(messages: [[String: String]]) async throws -> String {
        var request = URLRequest(url: URL(string: "\(host)/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GroqChatRequest(model: model, messages: messages, stream: false, reasoningEffort: reasoningEffort)
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
