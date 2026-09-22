import Foundation

/// Swift port of server/tinytalk/illustrations.py: one picture per storybook
/// page. First the chat model turns each page's prose into a one-sentence
/// scene description; then the pictures are drawn strictly in page order --
/// page 0 without a reference, later pages passing page 0's image as the
/// reference WHEN the backend supports one (FLUX.1 [schnell] doesn't, so
/// today every page is prompt-only). A page whose scene prompt or picture
/// fails simply has no picture and the pass carries on.
///
/// Two things the home pipeline doesn't need: a fixed style directive
/// prepended to every prompt (kept in one constant so it can be tuned
/// on-device), and a time budget for the drawing phase, checked before each
/// page, so a slow cloud service can't hold The End screen hostage.
public struct IllustrationPass: StoryIllustrating {
    // Two 45 s per-request timeouts back to back (a page 0 cold start, then
    // a still-warming page 1) already spend 90 s; 120 s leaves room for a
    // third attempt once Cloudflare is warm. Raised from 60 s after
    // on-device testing (2026-09-22) showed the original budget could
    // expire before a single picture succeeded. See ImageGeneration.swift's
    // timeoutInterval comment for the observed evidence.
    public static let defaultTimeBudget: TimeInterval = 120

    /// Prepended to every scene prompt. Tune this on-device -- it is the main
    /// lever for keeping the storybook's pictures looking like one book.
    public static let styleDirective =
        "A gentle, colorful children's picture-book illustration in a soft " +
        "watercolor style, friendly and child-appropriate. "

    /// illustrations.py's prompt-extraction template. Character consistency
    /// can't come from the model "remembering" earlier pages -- each page's
    /// scene prompt below is an independent, stateless call, so nothing
    /// carries between them except what illustrate(pages:) explicitly
    /// passes in. Once the FIRST page's scene description succeeds, its
    /// exact text is carried forward as `priorDescription` and given to
    /// every later page as a real anchor to match, instead of a generic
    /// example the model had nothing genuine to be consistent with.
    /// (On-device testing, 2026-09-22: an earlier version asked the model
    /// to reuse "the same short description... for example, 'a small
    /// orange fox'" on every page. With no real memory of its own past
    /// answers, the model had nothing else that stayed constant across the
    /// per-page calls, so it echoed that example verbatim from page 1
    /// onward -- fox illustrations in stories that never mentioned one.
    /// FLUX.1 [schnell] has no reference image, so a real prior-page anchor
    /// is the only consistency lever available here.)
    static func sceneRequest(pageText: String, priorDescription: String?) -> String {
        let consistency: String
        if let priorDescription {
            consistency = "For character consistency, the main character was already " +
                "described, on an earlier page of this same story, as: " +
                "\"\(priorDescription)\". Describe the same character the same way here, " +
                "even though the setting or action may be different. "
        } else {
            consistency = "Describe the main character specifically enough (species, " +
                "colour, size) that this exact description could be reused, unchanged, " +
                "on a later page. "
        }
        return "Describe this storybook page as a short visual scene for an " +
        "illustrator: setting, characters, action, and mood, in one " +
        "sentence, no more than 25 words. Do not mention that this is from " +
        "a story. " + consistency +
        "Reply with ONLY the scene description, no other text.\n\n" +
        "Page text: \(pageText)"
    }

    /// A URLError's default description embeds the failing URL, and the
    /// Cloudflare request URL contains the account id -- log only its code and
    /// message so a credential can never reach the debug log. Every other
    /// error (ImageGenerationError included) keeps its own description.
    private static func loggable(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)"
        }
        return "\(error)"
    }

    /// Every debug line carries the shared "[HH:mm:ss.SSS] " prefix: AppModel
    /// merges this log with the coordinator's and the audio engine's by plain
    /// string sort, which only interleaves correctly when every line starts
    /// with the timestamp (see DebugTimestamp).
    private func debug(_ message: String) {
        onDebugEvent?("[\(DebugTimestamp.now())] \(message)")
    }

    private let chat: any ChatCompleting
    private let backend: any ImageGenerating
    private let timeBudget: TimeInterval
    private let now: @Sendable () -> Date
    private let onDebugEvent: (@Sendable (String) -> Void)?

    public init(
        chat: any ChatCompleting,
        backend: any ImageGenerating,
        timeBudget: TimeInterval = IllustrationPass.defaultTimeBudget,
        now: @escaping @Sendable () -> Date = { Date() },
        onDebugEvent: (@Sendable (String) -> Void)? = nil
    ) {
        self.chat = chat
        self.backend = backend
        self.timeBudget = timeBudget
        self.now = now
        self.onDebugEvent = onDebugEvent
    }

    public func illustrate(pages: [String]) async -> IllustrationResult {
        // Phase 1: every page's scene prompt, in one quick burst (same order
        // of work as illustrations.py). `anchorDescription` is the first
        // successful scene description, reused verbatim in every later
        // page's prompt so the model has a real anchor for "same character"
        // instead of a fixed example (see sceneRequest's doc comment).
        var scenes: [String?] = []
        var anchorDescription: String?
        for (index, page) in pages.enumerated() {
            do {
                let scene = try await chat
                    .complete(messages: [["role": "user", "content": Self.sceneRequest(pageText: page, priorDescription: anchorDescription)]])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if scene.isEmpty {
                    debug("illustration: page \(index) scene prompt came back empty")
                    scenes.append(nil)
                } else {
                    debug("illustration: page \(index) scene prompt: \(scene)")
                    scenes.append(scene)
                    if anchorDescription == nil { anchorDescription = scene }
                }
            } catch {
                debug("illustration: page \(index) scene prompt failed: \(Self.loggable(error))")
                scenes.append(nil)
            }
        }

        // Phase 2: the pictures, strictly in page order. The time budget
        // starts HERE: it exists so a slow image service can't hold The End
        // hostage, and the scene sentences above come from the same chat
        // service the storybook rewrite has just used -- a slow scene phase
        // must not eat the drawing budget and cost every page its picture.
        let startedAt = now()
        var images: [Data?] = []
        var firstImage: Data?
        for (index, scene) in scenes.enumerated() {
            guard let scene else {
                images.append(nil)
                continue
            }
            if now().timeIntervalSince(startedAt) >= timeBudget {
                debug("illustration: time budget spent -- page \(index) gets no picture")
                images.append(nil)
                continue
            }
            do {
                let reference = backend.supportsReference ? firstImage : nil
                guard let raw = try await backend.generate(prompt: Self.styleDirective + scene, reference: reference) else {
                    debug("illustration: page \(index) was declined by the image backend")
                    images.append(nil)
                    continue
                }
                guard let jpeg = ImageDownscaler.jpeg(from: raw) else {
                    debug("illustration: page \(index) came back undecodable")
                    images.append(nil)
                    continue
                }
                if firstImage == nil { firstImage = raw }
                images.append(jpeg)
            } catch {
                debug("illustration: page \(index) failed: \(Self.loggable(error))")
                images.append(nil)
            }
        }

        let succeeded = images.compactMap { $0 }.count
        let status: IllustrationsStatus =
            succeeded == 0 ? .failed : (succeeded == images.count ? .done : .partial)
        debug("illustration: \(status.rawValue) (\(succeeded)/\(images.count) pages)")
        return IllustrationResult(images: images, status: status)
    }
}
