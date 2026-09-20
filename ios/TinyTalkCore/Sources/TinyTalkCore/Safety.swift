import Foundation

/// Swift port of server/tinytalk/safety.py. Deliberately NOT semantic
/// content understanding -- see that file's module docstring for the
/// full rationale (zero-latency denylist, not exhaustive moderation).
public enum Safety {
    public static let safeFallback = "Hmm, let's take the story somewhere else! What should happen next?"

    private static let violence = [
        "blood", "gun", "guns", "knife", "knives", "kill", "kills", "killed", "killing",
        "dead", "die", "dies", "died", "fight", "fights", "fighting",
        "hurt", "hurts", "hurting", "stab", "stabbed", "stabbing",
        "shoot", "shoots", "shooting",
    ]

    private static let frightening = [
        "monster attacking", "terrifying", "nightmare", "screamed in terror",
        "trapped forever", "pure evil", "demon", "demons",
    ]

    private static let adultThemes = ["drunk", "alcohol", "cigarette", "naked"]

    private static let realWorldDanger = [
        "play with matches", "playing with matches", "played with matches",
        "play with a lighter", "playing with a lighter", "played with a lighter",
        "poison", "drown", "drowned", "drowning", "jump off a cliff",
    ]

    private static let reproduction = [
        "mating", "breeding", "pregnant", "pregnancy", "reproduce", "reproduces",
        "reproducing", "reproduction", "sex", "sexual", "porn", "porno",
        "pornography", "pornographic", "nude", "nudity", "erotic",
        "masturbate", "masturbation", "orgasm",
    ]

    private static let profanity = [
        "damn", "hell", "shit", "fuck", "ass", "asshole", "bitch", "crap",
        "bastard", "piss", "dick", "whore", "slut",
    ]

    private static let allBlocked =
        violence + frightening + adultThemes + realWorldDanger + reproduction + profanity

    // Deliberately does NOT include "kiss" -- see safety.py's own comment.
    private static let safePhrases = ["shooting star", "shooting stars"]

    private static let blockedPattern: NSRegularExpression = {
        let escaped = allBlocked.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // swiftlint:disable:next force_try -- a fixed, compile-time-known pattern; a failure here is a bug in this file, not runtime input.
        return try! NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
    }()

    private static let safePattern: NSRegularExpression = {
        let escaped = safePhrases.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "\\b(?:\(escaped))\\b", options: .caseInsensitive)
    }()

    /// Every distinct blocked word/phrase matched in `text`, lowercased, in
    /// the order each first appears -- mirrors safety.py's find_blocked().
    /// Lets a caller (StorybookWriter's safety-retry loop, DemoConnection's
    /// forced-conclude retry) tell the model specifically what to avoid,
    /// not just that something was wrong. The safe-phrase mask runs first,
    /// exactly as in the Python original.
    public static func findBlocked(_ text: String) -> [String] {
        let fullRange = NSRange(text.startIndex..., in: text)
        let masked = safePattern.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        let maskedRange = NSRange(masked.startIndex..., in: masked)
        var found: [String] = []
        for match in blockedPattern.matches(in: masked, range: maskedRange) {
            let term = (masked as NSString).substring(with: match.range).lowercased()
            if !found.contains(term) { found.append(term) }
        }
        return found
    }

    public static func isSafe(_ text: String) -> Bool {
        findBlocked(text).isEmpty
    }

    public static func filterReply(_ text: String) -> String {
        (!text.isEmpty && isSafe(text)) ? text : safeFallback
    }
}
