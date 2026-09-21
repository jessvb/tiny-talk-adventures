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
/// on-device), and a total time budget checked before each page, so a slow
/// cloud service can't hold The End screen hostage.
public struct IllustrationPass: StoryIllustrating {
    public static let defaultTimeBudget: TimeInterval = 60

    /// Prepended to every scene prompt. Tune this on-device -- it is the main
    /// lever for keeping the storybook's pictures looking like one book.
    public static let styleDirective =
        "A gentle, colorful children's picture-book illustration in a soft " +
        "watercolor style, friendly and child-appropriate. "

    /// illustrations.py's prompt-extraction template, plus one sentence asking
    /// the model to name the main character the same way on every page
    /// (FLUX.1 [schnell] has no reference image to keep a character
    /// consistent, so consistency has to come from the words).
    static func sceneRequest(pageText: String) -> String {
        "Describe this storybook page as a short visual scene for an " +
        "illustrator: setting, characters, action, and mood, in one " +
        "sentence, no more than 25 words. Do not mention that this is from " +
        "a story. Always refer to the main character by the same short " +
        "description on every page (for example, \"a small orange fox\"). " +
        "Reply with ONLY the scene description, no other text.\n\n" +
        "Page text: \(pageText)"
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
        let startedAt = now()

        // Phase 1: every page's scene prompt, in one quick burst (same order
        // of work as illustrations.py).
        var scenes: [String?] = []
        for (index, page) in pages.enumerated() {
            do {
                let scene = try await chat
                    .complete(messages: [["role": "user", "content": Self.sceneRequest(pageText: page)]])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                scenes.append(scene.isEmpty ? nil : scene)
            } catch {
                onDebugEvent?("illustration: page \(index) scene prompt failed: \(error)")
                scenes.append(nil)
            }
        }

        // Phase 2: the pictures, strictly in page order.
        var images: [Data?] = []
        var firstImage: Data?
        for (index, scene) in scenes.enumerated() {
            guard let scene else {
                images.append(nil)
                continue
            }
            if now().timeIntervalSince(startedAt) >= timeBudget {
                onDebugEvent?("illustration: time budget spent -- page \(index) gets no picture")
                images.append(nil)
                continue
            }
            do {
                let reference = backend.supportsReference ? firstImage : nil
                guard let raw = try await backend.generate(prompt: Self.styleDirective + scene, reference: reference) else {
                    onDebugEvent?("illustration: page \(index) was declined by the image backend")
                    images.append(nil)
                    continue
                }
                guard let jpeg = ImageDownscaler.jpeg(from: raw) else {
                    onDebugEvent?("illustration: page \(index) came back undecodable")
                    images.append(nil)
                    continue
                }
                if firstImage == nil { firstImage = raw }
                images.append(jpeg)
            } catch {
                onDebugEvent?("illustration: page \(index) failed: \(error)")
                images.append(nil)
            }
        }

        let succeeded = images.compactMap { $0 }.count
        let status: IllustrationsStatus =
            succeeded == 0 ? .failed : (succeeded == images.count ? .done : .partial)
        onDebugEvent?("illustration: \(status.rawValue) (\(succeeded)/\(images.count) pages)")
        return IllustrationResult(images: images, status: status)
    }
}
