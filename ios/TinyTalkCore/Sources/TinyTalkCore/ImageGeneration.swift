import Foundation

public enum ImageGenerationError: Error, Sendable, Equatable {
    /// A non-2xx response (a bad or expired token, an exhausted free quota,
    /// a content-moderation refusal...). `detail` is the start of the body.
    case http(status: Int, detail: String)
    /// A 2xx response whose body wasn't the JSON shape this client expects.
    case malformedResponse
    /// A well-formed response that carried an empty image.
    case emptyImage
    /// The account id contained characters that could alter the request path.
    case invalidAccountId
}

/// The seam between DemoStoryLibrary's illustration pass and whatever draws
/// the pictures -- mirrors server/tinytalk/image_gen.py's ImageGenBackend, so
/// a different backend (another cloud service, an on-device model) can slot
/// in without touching the pass.
public protocol ImageGenerating: Sendable {
    /// True when the backend can take a reference image to keep a character
    /// consistent across pages (the home pipeline's IP-Adapter does).
    var supportsReference: Bool { get }

    /// Encoded image bytes in any format ImageDownscaler can read, or nil
    /// when the backend declined to draw this prompt.
    func generate(prompt: String, reference: Data?) async throws -> Data?
}

/// ImageGenerating backed by Cloudflare Workers AI's FLUX.1 [schnell], which
/// has a genuine free daily allowance (10,000 neurons/day, roughly 170
/// images) -- see docs/superpowers/specs/2026-09-19-demo-mode-parity-design.md
/// for the research and for why this over the alternatives. The request and
/// response shapes are from Cloudflare's model page
/// (developers.cloudflare.com/workers-ai/models/flux-1-schnell/): a `prompt`
/// (at most 2048 characters) and `steps` (default 4, at most 8) in, a base64
/// JPEG `image` out. Cloudflare's REST API wraps results in a v4 envelope
/// (`{"result": {...}, "success": true}`) while its Workers binding returns
/// the bare object, so both are accepted.
public final class CloudflareImageClient: ImageGenerating, @unchecked Sendable {
    public static let maxPromptCharacters = 2048

    /// FLUX.1 [schnell] takes no reference image.
    public let supportsReference = false

    private let accountId: String
    private let apiToken: String
    private let host: String
    private let steps: Int
    private let session: URLSession

    public init(
        accountId: String,
        apiToken: String,
        host: String = "https://api.cloudflare.com",
        steps: Int = 4,
        session: URLSession = .shared
    ) {
        self.accountId = accountId
        self.apiToken = apiToken
        self.host = host
        self.steps = steps
        self.session = session
    }

    public func generate(prompt: String, reference: Data?) async throws -> Data? {
        // The account id is typed in by a person and goes straight into the
        // URL path -- refuse anything that could change which endpoint this
        // reaches. (Cloudflare account ids are 32 hex characters.)
        guard !accountId.isEmpty, accountId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
              let url = URL(string: "\(host)/client/v4/accounts/\(accountId)/ai/run/@cf/black-forest-labs/flux-1-schnell")
        else { throw ImageGenerationError.invalidAccountId }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // URLRequest's default is 60 s -- the whole illustration pass's time
        // budget -- and IllustrationPass can only check that budget BEFORE
        // each page, so one stalled connection could hold The End for a full
        // minute. FLUX.1 [schnell] normally answers in a few seconds; a page
        // that times out simply gets no picture.
        request.timeoutInterval = 30
        let body: [String: Any] = ["prompt": String(prompt.prefix(Self.maxPromptCharacters)), "steps": steps]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImageGenerationError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw ImageGenerationError.http(status: http.statusCode, detail: detail)
        }
        return try Self.decodeImage(from: data)
    }

    static func decodeImage(from data: Data) throws -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImageGenerationError.malformedResponse
        }
        let payload = (object["result"] as? [String: Any]) ?? object
        guard let encoded = payload["image"] as? String,
              let image = Data(base64Encoded: encoded)
        else { throw ImageGenerationError.malformedResponse }
        guard !image.isEmpty else { throw ImageGenerationError.emptyImage }
        return image
    }
}
