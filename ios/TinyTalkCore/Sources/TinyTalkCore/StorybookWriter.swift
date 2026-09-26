import Foundation

/// A finished storybook rewrite -- what StorybookWriter returns on success.
public struct WrittenStorybook: Equatable, Sendable {
    public let title: String
    public let pages: [String]
    /// Always derived from a story's real shared facts, never model-written
    /// -- see StorybookWriter.write(). nil when no facts were shared.
    public let epilogue: String?

    public init(title: String, pages: [String], epilogue: String?) {
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
    }
}

/// Swift port of server/tinytalk/storybook.py's rewrite pass: turns a
/// finished story's raw transcript into picture-book pages (a title, prose
/// pages, and an optional fact-grounded epilogue) using the phone's own
/// chat client (Groq, in demo mode). Same prompts, same tolerant JSON
/// extraction, and the same shared attempt budget for its two retryable
/// failure modes (unparseable reply, kid-safety flag) as the Python
/// original -- see that file for the rationale behind each of them.
public struct StorybookWriter: Sendable {
    /// Mirrors config.STORYBOOK_REWRITE_RETRY_ATTEMPTS.
    public static let defaultMaxAttempts = 3

    static let systemPrompt =
        "You are writing a children's picture-book story for a young child, " +
        "aged about three to six, to read or be read to again later.\n" +
        "\n" +
        "Rules you always follow:\n" +
        "- Keep everything gentle and wholesome. No violence, no weapons, no death, " +
        "no frightening peril.\n" +
        "- Keep the story grounded in the real world: no magic, no talking " +
        "plants or objects, no impossible physics. Animal characters can " +
        "talk and think like people, but everything else about the world " +
        "should be realistic.\n" +
        "- Write plain prose only: no emoji, no asterisks, no stage directions."

    static let parseRetryPrompt =
        "That wasn't valid JSON. Reply again with ONLY the JSON object, in the " +
        "exact same shape as before -- no other text before or after it."

    static func safetyRetryPrompt(terms: String) -> String {
        "That version isn't appropriate for a young child's storybook -- it " +
        "mentioned: \(terms). Rewrite the whole story again from scratch, same " +
        "characters and events, but leave out any mention of that. Reply with " +
        "ONLY the JSON object again, in the same shape as before."
    }

    private let chat: any ChatCompleting
    private let maxAttempts: Int

    public init(chat: any ChatCompleting, maxAttempts: Int = StorybookWriter.defaultMaxAttempts) {
        self.chat = chat
        self.maxAttempts = max(1, maxAttempts)
    }

    private static func pairs(_ sharedFacts: [[String]]) -> [(animal: String, fact: String)] {
        sharedFacts.compactMap { pair in
            pair.count == 2 ? (animal: pair[0], fact: pair[1]) : nil
        }
    }

    /// The one place the epilogue's wording lives on the phone (mirrors
    /// storybook.py's derive_epilogue()); nil when no fact was shared.
    public static func epilogue(sharedFacts: [[String]]) -> String? {
        pairs(sharedFacts).first.map {
            "And one true thing we learned about the \($0.animal): \($0.fact)"
        }
    }

    /// The epilogue as sent with rewriting_started, before the rewrite
    /// runs (issue #77) -- with the same kid-safety check write() applies
    /// before saving it: nil if anything is flagged.
    public static func earlyEpilogue(sharedFacts: [[String]]) -> String? {
        guard let epilogue = epilogue(sharedFacts: sharedFacts),
              Safety.findBlocked(epilogue).isEmpty else { return nil }
        return epilogue
    }

    /// Returns nil for "failed": the reply never parsed, or stayed unsafe,
    /// after every attempt -- or the chat call itself threw. The caller
    /// keeps the raw transcript either way (same as storybook.py's
    /// "failed" status leaving `turns` untouched).
    public func write(turns: [PendingDemoStoryTurn], sharedFacts: [[String]], pageCount: Int) async -> WrittenStorybook? {
        let facts = Self.pairs(sharedFacts)
        // The spec requires the epilogue to always be a real fact the story
        // actually shared, never something the model invents -- so the
        // model's own "epilogue" text (whatever it is) is never used. When
        // real facts exist it is always formatted here, from the first one;
        // otherwise it is omitted, regardless of what the model volunteered.
        let epilogue = Self.epilogue(sharedFacts: sharedFacts)

        var messages: [[String: String]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": Self.buildPrompt(turns: turns, facts: facts, pageCount: pageCount)],
        ]

        for attempt in 1...maxAttempts {
            let raw: String
            do {
                raw = try await chat.complete(messages: messages)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }

            guard let parsed = Self.parse(raw) else {
                if attempt < maxAttempts {
                    messages.append(["role": "assistant", "content": raw])
                    messages.append(["role": "user", "content": Self.parseRetryPrompt])
                    continue
                }
                return nil
            }

            let textsToCheck = [parsed.title] + parsed.pages + (epilogue.map { [$0] } ?? [])
            var blocked: [String] = []
            for text in textsToCheck {
                for term in Safety.findBlocked(text) where !blocked.contains(term) {
                    blocked.append(term)
                }
            }
            blocked.sort()

            if blocked.isEmpty {
                return WrittenStorybook(title: parsed.title, pages: parsed.pages, epilogue: epilogue)
            }
            if attempt < maxAttempts {
                messages.append(["role": "assistant", "content": raw])
                messages.append(["role": "user", "content": Self.safetyRetryPrompt(terms: blocked.joined(separator: ", "))])
            }
        }
        return nil
    }

    static func buildPrompt(
        turns: [PendingDemoStoryTurn], facts: [(animal: String, fact: String)], pageCount: Int
    ) -> String {
        let transcript = turns.map { turn -> String in
            let speaker = turn.speaker == "child" ? "Child" : "Storyteller"
            return "\(speaker): \(turn.text)"
        }.joined(separator: "\n")

        var factsSection = ""
        var epilogueKey = ""
        if !facts.isEmpty {
            let factsList = facts.map { "\($0.animal): \($0.fact)" }.joined(separator: "; ")
            factsSection =
                "Real facts this story actually used: \(factsList). If natural, " +
                "close with one of these as a one-sentence epilogue, phrased for " +
                "a young child.\n\n"
            epilogueKey = #", "epilogue": "one true, real fact from the story, in one sentence""#
        }

        return
            "You are turning a story a child and a storyteller made up together " +
            "into a picture-book version for the child to read again later.\n\n" +
            "Here is the full conversation, in order:\n\(transcript)\n\n" +
            factsSection +
            "Rewrite this as a children's storybook: continuous third-person " +
            "narration that captures the same characters, events, and facts -- " +
            "NOT a dialogue transcript, and don't write \"the child said\" or " +
            "\"the storyteller said\" anywhere. Split it into exactly \(pageCount) " +
            "pages. Reply with ONLY a JSON object, no other text, in this exact " +
            "shape:\n" +
            #"{"title": "...", "pages": [{"text": "..."}, ...]"# + epilogueKey + "}"
    }

    /// Extracts {title, pages} from the model's raw reply, tolerant of
    /// leading/trailing prose around the JSON object (a small model doesn't
    /// reliably follow "reply with ONLY json"). nil if nothing usable is
    /// found. Deliberately ignores any "epilogue" the model returned.
    static func parse(_ raw: String) -> (title: String, pages: [String])? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTitle = object["title"] as? String,
              case let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let rawPages = object["pages"] as? [Any],
              !rawPages.isEmpty
        else { return nil }

        var pages: [String] = []
        for entry in rawPages {
            guard let page = entry as? [String: Any], let text = page["text"] as? String else { return nil }
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (title, pages)
    }
}
