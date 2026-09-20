# Demo Mode Parity — Phase 2: Away-From-Home Illustrations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Storybooks made away from home get a picture on every page, drawn by Cloudflare Workers AI's free FLUX.1 [schnell] — optional (text-only without credentials), never able to delay or break a story — and those pictures travel with the story to the Mac at sync time.

**Architecture:** Phase 1 already gave `DemoStoryLibrary` a `StoryIllustrating` seam (a `nil` illustrator means text-only), taught `DemoConnection` to serve page images (`get_page_image`), put images on the sync wire, and taught the server to validate and re-encode them. Phase 2 supplies the illustrator: a swappable `ImageGenerating` backend with a Cloudflare implementation, an `ImageDownscaler` that shrinks whatever comes back to ≤ 512 px JPEG, and an `IllustrationPass` (a Swift port of `server/tinytalk/illustrations.py`) that asks Groq for a one-sentence scene per page and draws the pages in order under a time budget. Two secure Settings fields feed `AppModel`, which builds the pass only when both credentials are stored.

**Tech Stack:** Swift 6 / XCTest in `ios/TinyTalkCore` (ImageIO/CoreGraphics for downscaling, URLSession for Cloudflare; no new dependencies), SwiftUI app target (`AppModel`, `SettingsView`). No server changes.

**Spec:** `docs/superpowers/specs/2026-09-19-demo-mode-parity-design.md` (approved 2026-09-19; PR #44). **Prerequisite:** Phase 1, `docs/superpowers/plans/2026-09-20-demo-mode-phase-1-local-storybook.md`, must be merged (or you must branch from its head).

**Refinement of the spec's phasing.** The spec lists `get_page_image` and "uploading images with the sync payload" under Phase 2. While building Phase 1 it made more sense to ship them there — `DemoConnection` is one file, and the sync payload/server validator define the wire format once (the spec's own Phase 1 text already says the validator "handles images from the start"). Both were unit-tested in Phase 1 with fake illustrators and synthetic images. So this phase is only the image *source* and its wiring.

## Global Constraints

- **Optional and free.** "Illustrations are enabled only when both are present" (Cloudflare account id and API token). "No Cloudflare credentials: text-only storybooks, silently." Nothing here may make credentials mandatory.
- **Cloudflare request shape (verified 2026-09-19 against the model page; re-check before relying):** `POST /client/v4/accounts/{account_id}/ai/run/@cf/black-forest-labs/flux-1-schnell`, header `Authorization: Bearer {token}`, JSON `prompt` (required, ≤ 2048 chars) and `steps` (default 4, max 8); no width/height parameter is documented; the image comes back as a base64 JPEG. Free allocation: 10,000 neurons/day (about 170 images/day, roughly 34 five-page stories, by a secondary calculation — re-check the exact figure).
- **Images are stored and uploaded at ≤ 512 px on the long side, JPEG quality ≈ 0.8** (~50–100 KB) — comfortably inside the server's "each image ≤ 1.5 MB decoded" limit.
- **The illustration pass mirrors `illustrations.py`:** scene descriptions first ("one-sentence, ≤ 25-word"), then pictures **strictly in page order**; page 0 without a reference, later pages pass page 0's image only when the backend `supportsReference` (FLUX.1 [schnell] does not). A page whose scene or picture fails simply has no picture; status is `done` (all pages), `partial` (some), `failed` (none).
- **Time budget:** "a total time budget (default 60 s) checked before each page so a slow Cloudflare can't hold The End hostage"; pages not reached have no picture and the status reflects it. 60 s is a starting value, tuned on-device.
- **Nothing child-visible on failure:** a bad or expired token, or an exhausted quota, is "treated as an image failure, with one line in the debug log".
- **Privacy exception (disclosed in the spec):** story scene text goes to Cloudflare to produce images — parent-gated, optional, off unless credentials are entered. Credentials live in the Keychain (`KeychainStore` keys `cloudflareAccountId`, `cloudflareApiToken`), never in source, UserDefaults, or logs.
- **Repo rules (`CLAUDE.md`):** small commits, one per task; never push to `main`; a PR for the household to review; concrete on-device instructions after implementing (Task 5).

## How to use this plan

**Provenance.** Every code block was extracted programmatically from the implementation that was built and verified on the scratch branch `scratch-demo-mode-verified` (local only; Phase 2 = commit `62b55d3`, on top of Phase 1's `d43aa4a`): 362 Swift tests with 0 failures, `xcodebuild` BUILD SUCCEEDED. Copy blocks exactly; if something does not compile or pass, suspect a transcription slip or a moved base and investigate rather than "improving" the block.

**Block conventions.** A `swift` block under "Create" is the complete file. A `diff` block is a unified diff against the file **as it is on your branch now** (`+` added, `-` removed, other lines are context to match; hunk line numbers may drift). A block introduced with "Append" goes at the end of the named file after a blank line.

**Test commands.** `swift test` prints roughly a million log lines from a ditty-loop test — **always redirect to a file and grep the summary**, as two plain commands (any scratch path unique to your session; `<WT>` below is this phase's worktree, see Preflight):

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkCore --filter SomeTestClass > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | grep -v "ditty loop" | tail -5
```

The XCTest count is the last `Executed N tests` line (the file ends with a Swift Testing "0 tests" footer). `testPageAudioDittyStopsOnStopPageAudio` is a known flake (~2 in 40 runs on unmodified `main`): if it is the only failure in a full run, re-run it alone.

**Commits.** One per task, `git -C <worktree>` with plain single commands; add your harness's attribution trailers.

## Preflight (do once, before Task 1)

- [ ] **Create this phase's worktree from a `main` that contains Phase 1** (after Phase 1's PR merges):

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures fetch origin
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures worktree add -b worktree-demo-mode-phase-2 /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 origin/main
```

(If Phase 1 has not merged yet, branch from its head instead: replace `origin/main` with `worktree-demo-mode-phase-1`, and retarget this phase's PR to `main` once Phase 1 merges.)

- [ ] **Recreate the gitignored signing config** (a fresh worktree lacks it; the team id comes from the example file):

```bash
cp -n ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkApp/Local.xcconfig.example ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkApp/Local.xcconfig
```

- [ ] **Record the baseline** with the whole-suite recipe above (no `--filter`). With Phase 1 merged onto the spec-commit base it is **333** Swift tests; every count below is "baseline + N" (the per-task `+N` figures are exact; absolute totals assume 333). Confirm Phase 1's files are present: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoStoryLibrary.swift` must define `StoryIllustrating` and `IllustrationResult`.

## File Structure

**Create (under `ios/TinyTalkCore/Sources/TinyTalkCore/` unless noted)**

| File | Responsibility |
|---|---|
| `ImageGeneration.swift` | `ImageGenerating` (the swappable backend seam), `ImageGenerationError`, and `CloudflareImageClient` — the FLUX.1 [schnell] call over a `URLSession`. |
| `ImageDownscaler.swift` | Re-encodes any image ImageIO can read to ≤ 512 px JPEG (~0.8 quality). |
| `IllustrationPass.swift` | The `StoryIllustrating` implementation: scene prompts from Groq, pictures in page order, style directive, time budget, status. |
| `Tests/TinyTalkCoreTests/ImageFakes.swift` | Test doubles: `TestImages` (real, decodable images), `FakeImageBackend`, `FakeClock`, `DebugLog`. |
| `Tests/TinyTalkCoreTests/CloudflareImageClientTests.swift`, `ImageDownscalerTests.swift`, `IllustrationPassTests.swift` | Tests for the above. |

**Modify:** `ios/TinyTalkApp/TinyTalkApp/AppModel.swift` (`makeIllustrator`, passed into the library) and `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift` (two secure fields).

---

### Task 1: `ImageGenerating` and `CloudflareImageClient`

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/ImageGeneration.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/CloudflareImageClientTests.swift`

**Interfaces:**
- Consumes: Foundation's `URLSession` (injected, so tests use a stub `URLProtocol` and no test touches the network).
- Produces: `ImageGenerationError` (`.http(status:detail:)`, `.malformedResponse`, `.emptyImage`, `.invalidAccountId`); `protocol ImageGenerating: Sendable { var supportsReference: Bool { get }; func generate(prompt: String, reference: Data?) async throws -> Data? }` (`nil` = the backend declined to draw this prompt); `CloudflareImageClient(accountId:apiToken:host:steps:session:)` (`host` defaults to `https://api.cloudflare.com`, `steps` to 4, `session` to `.shared`), `supportsReference == false`, `static let maxPromptCharacters = 2048`. It accepts both the v4 REST envelope (`{"result": {"image": …}, "success": true}`) and the bare `{"image": …}` object, refuses account ids that could alter the URL path, and truncates prompts to 2048 characters.

- [ ] **Step 1: Create the tests.**

````swift
import XCTest
@testable import TinyTalkCore

final class CloudflareImageClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(accountId: String = "acct123") -> CloudflareImageClient {
        CloudflareImageClient(accountId: accountId, apiToken: "test-token", session: makeSession())
    }

    /// URLProtocol hands the handler the request with its body moved into
    /// httpBodyStream, so read it from there.
    private func bodyObject(of request: URLRequest) -> [String: Any]? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func envelope(image: String) -> Data {
        Data(#"{"result":{"image":"\#(image)"},"success":true,"errors":[],"messages":[]}"#.utf8)
    }

    func testTheRequestIsAnAuthenticatedPostToTheFluxSchnellEndpoint() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, self.envelope(image: Data([1, 2, 3]).base64EncodedString()))
        }

        _ = try await makeClient().generate(prompt: "a small orange fox", reference: nil)

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://api.cloudflare.com/client/v4/accounts/acct123/ai/run/@cf/black-forest-labs/flux-1-schnell"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(bodyObject(of: request))
        XCTAssertEqual(body["prompt"] as? String, "a small orange fox")
        XCTAssertEqual(body["steps"] as? Int, 4)
    }

    func testTheImageIsDecodedFromTheV4Envelope() async throws {
        StubURLProtocol.handler = { _ in (200, self.envelope(image: Data([9, 8, 7]).base64EncodedString())) }
        let image = try await makeClient().generate(prompt: "x", reference: nil)
        XCTAssertEqual(image, Data([9, 8, 7]))
    }

    func testTheImageIsAlsoDecodedFromABareObject() async throws {
        // The Workers binding returns {"image": ...} with no envelope.
        StubURLProtocol.handler = { _ in (200, Data(#"{"image":"\#(Data([5, 5]).base64EncodedString())"}"#.utf8)) }
        let image = try await makeClient().generate(prompt: "x", reference: nil)
        XCTAssertEqual(image, Data([5, 5]))
    }

    func testAPromptOverTheLimitIsTruncatedToTwoThousandFortyEightCharacters() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, self.envelope(image: Data([1]).base64EncodedString()))
        }
        _ = try await makeClient().generate(prompt: String(repeating: "a", count: 5000), reference: nil)
        let prompt = try XCTUnwrap(bodyObject(of: try XCTUnwrap(captured))?["prompt"] as? String)
        XCTAssertEqual(prompt.count, CloudflareImageClient.maxPromptCharacters)
    }

    func testAReferenceImageIsIgnoredBecauseFluxSchnellTakesNone() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            return (200, self.envelope(image: Data([1]).base64EncodedString()))
        }
        let client = makeClient()
        XCTAssertFalse(client.supportsReference)
        _ = try await client.generate(prompt: "x", reference: Data([1, 2, 3]))
        let body = try XCTUnwrap(bodyObject(of: try XCTUnwrap(captured)))
        XCTAssertEqual(Set(body.keys), Set(["prompt", "steps"]))
    }

    // MARK: - failures

    func testANon2xxStatusThrowsAnHTTPErrorCarryingTheStatusAndBody() async {
        StubURLProtocol.handler = { _ in (401, Data("Authentication error".utf8)) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .http(status: 401, detail: "Authentication error"))
        }
    }

    func testAResponseWithNoImageIsMalformed() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"result":{},"success":false}"#.utf8)) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .malformedResponse)
        }
    }

    func testABodyThatIsNotJSONIsMalformed() async {
        StubURLProtocol.handler = { _ in (200, Data("<html>gateway</html>".utf8)) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .malformedResponse)
        }
    }

    func testInvalidBase64IsMalformed() async {
        StubURLProtocol.handler = { _ in (200, self.envelope(image: "!!! not base64 !!!")) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .malformedResponse)
        }
    }

    func testAnEmptyImageIsReportedAsSuch() async {
        StubURLProtocol.handler = { _ in (200, self.envelope(image: "")) }
        do {
            _ = try await makeClient().generate(prompt: "x", reference: nil)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ImageGenerationError, .emptyImage)
        }
    }

    func testAnAccountIdThatCouldChangeTheRequestPathIsRefusedBeforeAnyNetworkCall() async {
        StubURLProtocol.handler = { _ in
            XCTFail("no request may be sent for an invalid account id")
            return (200, Data())
        }
        for bad in ["", "../other", "acct/123", "acct 123", "acct?x=1"] {
            do {
                _ = try await makeClient(accountId: bad).generate(prompt: "x", reference: nil)
                XCTFail("expected \(bad.debugDescription) to be refused")
            } catch {
                XCTAssertEqual(error as? ImageGenerationError, .invalidAccountId, "for \(bad.debugDescription)")
            }
        }
    }
}
````

- [ ] **Step 2: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkCore --filter CloudflareImageClientTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `cannot find 'CloudflareImageClient' in scope`.

- [ ] **Step 3: Implement.**

````swift
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
````

- [ ] **Step 4: Run the tests and watch them pass.** Same two commands as Step 2. Expected: `Executed 11 tests, with 0 failures`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 add ios/TinyTalkCore/Sources/TinyTalkCore/ImageGeneration.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/CloudflareImageClientTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 commit -m "feat(ios): ImageGenerating seam and CloudflareImageClient (FLUX.1 schnell)" -m "Swappable image backend plus its Cloudflare Workers AI implementation. Accepts the v4 REST envelope or the bare object, refuses account ids that could alter the request path, truncates prompts to the documented 2048 characters, and maps every failure to a typed error. No test touches the network."
```

- [ ] **Step 6: Re-check the free-tier figures** (the spec asks for this at implementation time). Open `developers.cloudflare.com/workers-ai/platform/pricing/` and the FLUX.1 [schnell] model page. If the free daily allocation (10,000 neurons/day) or the per-image cost (≈ 58 neurons for a default 1024×1024, 4-step image → about 170 images/day) differs materially, note the new figure in the PR description; nothing in the code depends on it.

- [ ] **Step 7: Household check of the real response envelope** (needs the household's own Cloudflare credentials, so **do not block the rest of the work on it** — Tasks 2–4 proceed regardless; report the result in the PR). The client accepts both known shapes, but the spec wants a real response to confirm it. In a terminal, with the household's credentials exported (never committed, never pasted into a file in the repo):

```bash
export CF_ACCOUNT_ID=<your 32-character Cloudflare account id>
```
```bash
export CF_API_TOKEN=<an API token with Workers AI permission>
```
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/ai/run/@cf/black-forest-labs/flux-1-schnell" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" -d '{"prompt":"A gentle, colorful children'"'"'s picture-book illustration of a small orange fox in a meadow","steps":4}' -o /tmp/cf-response.json
```
```bash
python3 -c "import json,base64; d=json.load(open('/tmp/cf-response.json')); r=d.get('result', d); print('top-level keys:', sorted(d)); print('image field present:', 'image' in r); open('/tmp/cf-image.jpg','wb').write(base64.b64decode(r['image']))"
```
```bash
file /tmp/cf-image.jpg
```

Expected: top-level keys include `result` and `success` (or just `image`), `image field present: True`, and `file` reports a JPEG image. Open `/tmp/cf-image.jpg` to eyeball the style. If the shape is different (for example the image is nested elsewhere), stop and adjust `CloudflareImageClient.decodeImage(from:)` and its tests before continuing to on-device testing.

---

### Task 2: `ImageDownscaler`

Whatever the backend returns is re-encoded to a small JPEG before it is stored, displayed or uploaded.

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/ImageDownscaler.swift`
- Create: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ImageFakes.swift` (first slice: `TestImages`)
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ImageDownscalerTests.swift`

**Interfaces:**
- Consumes: ImageIO / CoreGraphics / UniformTypeIdentifiers (system frameworks).
- Produces: `ImageDownscaler.jpeg(from data: Data, maxLongSide: Int = 512, quality: Double = 0.8) -> Data?` — a JPEG whose long side is at most `maxLongSide` (never upscaled), or `nil` when `data` is not a decodable image. Test helper `TestImages` (generates real PNG/JPEG bytes of a given size with CoreGraphics).

- [ ] **Step 1: Create the shared image test helpers with their first double.**

````swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import TinyTalkCore

/// Real, decodable image bytes generated with CoreGraphics -- so the
/// downscaler and illustration pass are tested against genuine image data,
/// not placeholder bytes it would (correctly) refuse to decode.
enum TestImages {
    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.starts(with: [0xFF, 0xD8, 0xFF])
    }
}
````

- [ ] **Step 2: Create the tests.**

````swift
import XCTest
@testable import TinyTalkCore

final class ImageDownscalerTests: XCTestCase {
    func testALargePNGBecomesAJPEGWithItsLongSideAtMostFiveHundredTwelve() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 1024, height: 768)))
        XCTAssertTrue(TestImages.isJPEG(jpeg))
        let size = try XCTUnwrap(TestImages.pixelSize(of: jpeg))
        XCTAssertEqual(max(size.width, size.height), 512)
        XCTAssertEqual(Double(size.width) / Double(size.height), 4.0 / 3.0, accuracy: 0.02, "the aspect ratio must be kept")
    }

    func testATallImageIsLimitedOnItsHeight() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 600, height: 1200)))
        let size = try XCTUnwrap(TestImages.pixelSize(of: jpeg))
        XCTAssertEqual(size.height, 512)
        XCTAssertEqual(size.width, 256)
    }

    func testAnImageAlreadySmallerThanTheLimitIsNeverLargerThanTheLimit() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 100, height: 50)))
        XCTAssertTrue(TestImages.isJPEG(jpeg))
        let size = try XCTUnwrap(TestImages.pixelSize(of: jpeg))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
    }

    func testTheOutputIsSmallEnoughToUploadCheaply() throws {
        let jpeg = try XCTUnwrap(ImageDownscaler.jpeg(from: TestImages.png(width: 1024, height: 1024)))
        XCTAssertLessThan(jpeg.count, 100_000)
    }

    func testBytesThatAreNotAnImageGiveNil() {
        XCTAssertNil(ImageDownscaler.jpeg(from: Data("definitely not an image".utf8)))
        XCTAssertNil(ImageDownscaler.jpeg(from: Data()))
    }
}
````

- [ ] **Step 3: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkCore --filter ImageDownscalerTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `cannot find 'ImageDownscaler' in scope`.

- [ ] **Step 4: Implement.**

````swift
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a generated picture as a small JPEG. Cloudflare returns a
/// full-size (about 1024 px) image; a storybook page on a phone never needs
/// more than ~512 px, and the same bytes are what get uploaded to the Mac at
/// sync time -- so shrinking once, here, keeps both local storage and the
/// upload payload small (roughly 50-100 KB a page).
public enum ImageDownscaler {
    /// At most `maxLongSide` pixels on the long side, aspect ratio kept, JPEG.
    /// nil when `data` isn't an image ImageIO can decode.
    public static func jpeg(from data: Data, maxLongSide: Int = 512, quality: Double = 0.8) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
````

- [ ] **Step 5: Run the tests and watch them pass.** Same two commands as Step 3. Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 6: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 add ios/TinyTalkCore/Sources/TinyTalkCore/ImageDownscaler.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ImageFakes.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ImageDownscalerTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 commit -m "feat(ios): ImageDownscaler re-encodes pictures to a small JPEG" -m "At most 512 px on the long side, quality 0.8, never upscaled; returns nil for bytes that are not an image. Keeps stored and uploaded pictures around 50-100 KB."
```

---

### Task 3: `IllustrationPass`

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/IllustrationPass.swift`
- Modify (append fakes): `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ImageFakes.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/IllustrationPassTests.swift`

**Interfaces:**
- Consumes: `ChatCompleting` (scene prompts, via the existing Groq client), `ImageGenerating` (Task 1), `ImageDownscaler.jpeg(from:)` (Task 2), `StoryIllustrating` / `IllustrationResult` (Phase 1), `IllustrationsStatus`.
- Produces: `IllustrationPass(chat:backend:timeBudget:now:onDebugEvent:)` conforming to `StoryIllustrating` — `timeBudget` defaults to `IllustrationPass.defaultTimeBudget` (60 s), `now` to `{ Date() }` (injectable so tests control time), `onDebugEvent` to `nil`; `illustrate(pages:) async -> IllustrationResult` returns one entry per page (`nil` = no picture) and `done` / `partial` / `failed`; `static let styleDirective` (prepended to every scene prompt; tune on-device); `static func sceneRequest(pageText:) -> String`. Test doubles `FakeImageBackend`, `FakeClock`, `DebugLog`.

- [ ] **Step 1: Append the remaining test doubles to `ImageFakes.swift`.**

````swift
/// Scripted ImageGenerating: one result per call (the last repeats), a record
/// of every call, and an optional hook that runs on each call (used to
/// advance a FakeClock).
final class FakeImageBackend: ImageGenerating, @unchecked Sendable {
    struct Call: Equatable {
        let prompt: String
        let reference: Data?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let results: [Result<Data?, Error>]
    private var _onGenerate: (@Sendable () -> Void)?
    let supportsReference: Bool

    init(supportsReference: Bool = false, results: [Result<Data?, Error>]) {
        self.supportsReference = supportsReference
        self.results = results
    }

    var calls: [Call] { lock.withLock { _calls } }

    var onGenerate: (@Sendable () -> Void)? {
        get { lock.withLock { _onGenerate } }
        set { lock.withLock { _onGenerate = newValue } }
    }

    func generate(prompt: String, reference: Data?) async throws -> Data? {
        let (result, hook): (Result<Data?, Error>, (@Sendable () -> Void)?) = lock.withLock {
            _calls.append(Call(prompt: prompt, reference: reference))
            return (results[min(_calls.count - 1, results.count - 1)], _onGenerate)
        }
        hook?()
        return try result.get()
    }
}

/// A clock the test moves by hand.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Collects debug lines emitted by an @Sendable onDebugEvent hook.
final class DebugLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []

    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}
````

- [ ] **Step 2: Create the tests.**

````swift
import XCTest
@testable import TinyTalkCore

/// Mirrors server/tests/test_illustrations.py's cases for illustrations.py.
final class IllustrationPassTests: XCTestCase {
    private let pages = ["Page one.", "Page two.", "Page three."]
    private let fullSize = TestImages.png(width: 1024, height: 768)

    private func sceneChat() -> ScriptedChatClient {
        ScriptedChatClient("a small orange fox in a meadow", "the small orange fox meets an owl", "the small orange fox goes home")
    }

    private func pass(
        chat: any ChatCompleting,
        backend: FakeImageBackend,
        timeBudget: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() },
        log: DebugLog? = nil
    ) -> IllustrationPass {
        IllustrationPass(
            chat: chat, backend: backend, timeBudget: timeBudget, now: now,
            onDebugEvent: log.map { log in { @Sendable line in log.append(line) } }
        )
    }

    // MARK: - happy path

    func testEveryPageGetsAPictureAndTheStatusIsDone() async {
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.images.count, 3)
        for image in result.images {
            let data = try! XCTUnwrap(image)
            XCTAssertTrue(TestImages.isJPEG(data), "pictures are stored as JPEG")
            let size = try! XCTUnwrap(TestImages.pixelSize(of: data))
            XCTAssertLessThanOrEqual(max(size.width, size.height), 512, "and downscaled to at most 512 px")
        }
    }

    func testEachPromptIsTheStyleDirectiveFollowedByThatPagesScene() async {
        let backend = FakeImageBackend(results: [.success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertEqual(backend.calls.map(\.prompt), [
            IllustrationPass.styleDirective + "a small orange fox in a meadow",
            IllustrationPass.styleDirective + "the small orange fox meets an owl",
            IllustrationPass.styleDirective + "the small orange fox goes home",
        ])
    }

    func testTheSceneRequestCarriesThePageTextAndTheTwentyFiveWordLimit() async {
        let chat = sceneChat()
        let backend = FakeImageBackend(results: [.success(fullSize)])
        _ = await pass(chat: chat, backend: backend).illustrate(pages: pages)

        XCTAssertEqual(chat.callCount, 3, "one scene prompt per page")
        let request = chat.receivedMessages[1][0]["content"] ?? ""
        XCTAssertTrue(request.contains("Page text: Page two."))
        XCTAssertTrue(request.contains("no more than 25 words"))
        XCTAssertTrue(request.contains("same short description on every page"))
    }

    // MARK: - reference images (character consistency)

    func testALaterPageGetsPageZerosImageAsItsReferenceWhenTheBackendSupportsOne() async {
        let backend = FakeImageBackend(supportsReference: true, results: [.success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertNil(backend.calls[0].reference, "page 0 is drawn reference-free")
        XCTAssertEqual(backend.calls[1].reference, fullSize)
        XCTAssertEqual(backend.calls[2].reference, fullSize)
    }

    func testNoReferenceIsSentWhenTheBackendCannotUseOne() async {
        let backend = FakeImageBackend(supportsReference: false, results: [.success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertTrue(backend.calls.allSatisfy { $0.reference == nil })
    }

    // MARK: - partial and total failure

    func testOnePagesFailureLeavesItPictureLessAndTheRestContinue() async {
        let backend = FakeImageBackend(results: [
            .success(fullSize), .failure(ImageGenerationError.http(status: 500, detail: "boom")), .success(fullSize),
        ])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)

        XCTAssertEqual(result.status, .partial)
        XCTAssertNotNil(result.images[0])
        XCTAssertNil(result.images[1])
        XCTAssertNotNil(result.images[2])
        XCTAssertEqual(backend.calls.count, 3, "a failure must not stop the later pages")
    }

    func testEveryPageFailingMarksTheWholePassFailed() async {
        let backend = FakeImageBackend(results: [.failure(ImageGenerationError.http(status: 401, detail: "bad token"))])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.images.compactMap { $0 }.count, 0)
    }

    func testABackendThatDeclinesLeavesThatPagePictureLess() async {
        let backend = FakeImageBackend(results: [.success(fullSize), .success(nil), .success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.images[1])
    }

    func testBytesThatAreNotAnImageLeaveThatPagePictureLessInsteadOfCrashing() async {
        let backend = FakeImageBackend(results: [.success(Data("not an image".utf8)), .success(fullSize), .success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: pages)
        XCTAssertEqual(result.status, .partial)
        XCTAssertNil(result.images[0])
    }

    func testAPageWhoseScenePromptFailsIsSkippedWithoutCallingTheBackend() async {
        // A scripted client can't fail on just one call, so use two: the
        // first call throws, later ones succeed.
        final class FlakyChat: ChatCompleting, @unchecked Sendable {
            private let lock = NSLock()
            private var calls = 0
            func complete(messages: [[String: String]]) async throws -> String {
                let call = lock.withLock { () -> Int in calls += 1; return calls }
                if call == 1 { throw DemoConnectionError.groqError("rate limited") }
                return "a small orange fox"
            }
        }
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: FlakyChat(), backend: backend).illustrate(pages: pages)

        XCTAssertNil(result.images[0])
        XCTAssertNotNil(result.images[1])
        XCTAssertNotNil(result.images[2])
        XCTAssertEqual(backend.calls.count, 2, "no scene prompt, so nothing to draw for page 0")
        XCTAssertEqual(result.status, .partial)
    }

    func testAStoryWithNoPagesIsFailedNotDone() async {
        let backend = FakeImageBackend(results: [.success(fullSize)])
        let result = await pass(chat: sceneChat(), backend: backend).illustrate(pages: [])
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.images.count, 0)
    }

    // MARK: - time budget

    func testPagesNotReachedBeforeTheTimeBudgetRunsOutGetNoPicture() async {
        let clock = FakeClock()
        let backend = FakeImageBackend(results: [.success(fullSize)])
        backend.onGenerate = { clock.advance(40) } // each picture "takes" 40 s
        let result = await pass(chat: sceneChat(), backend: backend, timeBudget: 60, now: { clock.now() })
            .illustrate(pages: pages)

        // Page 0 starts at 0 s, page 1 at 40 s (both < 60); page 2 would
        // start at 80 s -- past the budget, so it is skipped.
        XCTAssertEqual(backend.calls.count, 2)
        XCTAssertNotNil(result.images[0])
        XCTAssertNotNil(result.images[1])
        XCTAssertNil(result.images[2])
        XCTAssertEqual(result.status, .partial)
    }

    // MARK: - diagnostics

    func testFailuresAndTheFinalStatusReachTheDebugLog() async {
        let log = DebugLog()
        let backend = FakeImageBackend(results: [.success(fullSize), .failure(ImageGenerationError.emptyImage), .success(fullSize)])
        _ = await pass(chat: sceneChat(), backend: backend, log: log).illustrate(pages: pages)

        XCTAssertTrue(log.lines.contains { $0.contains("page 1 failed") })
        XCTAssertEqual(log.lines.last, "illustration: partial (2/3 pages)")
    }
}
````

- [ ] **Step 3: Run them and watch them fail to compile.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkCore --filter IllustrationPassTests > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | tail -5
```

Expected: `error:` lines — `cannot find 'IllustrationPass' in scope`.

- [ ] **Step 4: Implement.**

````swift
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
````

- [ ] **Step 5: Run the tests and watch them pass.** Same two commands as Step 3. Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 6: Run the whole Swift suite.**

```bash
swift test --package-path ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkCore > /tmp/demo-mode-swift.txt 2>&1
```
```bash
grep -E "Executed [0-9]+ tests?|error:" /tmp/demo-mode-swift.txt | grep -v "ditty loop" | tail -3
```

Expected: `Executed 362 tests, with 0 failures` (333 baseline + 11 + 5 + 13).

- [ ] **Step 7: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 add ios/TinyTalkCore/Sources/TinyTalkCore/IllustrationPass.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/ImageFakes.swift ios/TinyTalkCore/Tests/TinyTalkCoreTests/IllustrationPassTests.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 commit -m "feat(ios): IllustrationPass draws one picture per storybook page" -m "Swift port of illustrations.py: a scene sentence per page from the chat model, then pictures strictly in page order. Adds a fixed style directive and a 60 s total time budget so a slow cloud service cannot hold The End hostage; a failed page has no picture and the status is done/partial/failed."
```

---

### Task 4: Settings fields and `AppModel` wiring, then a build

The app target has no unit-test target; this task is verified by a build and by Task 5's on-device script. Everything logic-bearing is already tested in `TinyTalkCore`.

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`

**Interfaces:**
- Consumes: `IllustrationPass`, `CloudflareImageClient` (Tasks 1 and 3), `DemoStoryLibrary(store:writer:illustrator:)` (Phase 1), `KeychainStore.get(_:)` / `.set(_:forKey:)` / `.delete(_:)` (existing), `AppModel.appendAudioDebugEvent(_:)` (existing on-screen debug log).
- Produces: two secure fields in Settings' hidden away-from-home card (Keychain keys `cloudflareAccountId`, `cloudflareApiToken`); `AppModel.makeIllustrator(chat:) -> (any StoryIllustrating)?` returning `nil` unless **both** are stored and non-empty; `connectAwayFromHome()` passes it as the library's `illustrator`. The illustration pass's debug lines appear in the debug log.

- [ ] **Step 1: Add the Settings fields.** Apply this diff to `SettingsView.swift`:

````diff
--- a/ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
+++ b/ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
@@ -25,6 +25,8 @@ struct SettingsView: View {
     @State private var showAwayFromHomeCard = false
     @State private var groqApiKey: String = KeychainStore.get("groqApiKey") ?? ""
     @State private var animalFactsApiKey: String = KeychainStore.get("animalFactsApiKey") ?? ""
+    @State private var cloudflareAccountId: String = KeychainStore.get("cloudflareAccountId") ?? ""
+    @State private var cloudflareApiToken: String = KeychainStore.get("cloudflareApiToken") ?? ""
     /// Voice picker opens as its own sheet (same pattern as
     /// showDebugLogSheet below), not an inline Picker(.pickerStyle(.menu))
     /// -- confirmed on-device (2026-09-14) that .menu's UIMenu rendering
@@ -282,6 +284,36 @@ struct SettingsView: View {
                         }
                     }
 
+                Text("Optional -- pictures for away-from-home storybooks. Needs a free Cloudflare account: its account id and an API token (Workers AI). Without both, storybooks are text-only.")
+                    .font(TTA.Typography.body(12.5))
+                    .foregroundColor(TTA.Palette.inkSoft)
+
+                SecureField("Cloudflare account id (optional -- pictures)", text: $cloudflareAccountId)
+                    .font(.system(.body, design: .monospaced))
+                    .padding(11)
+                    .background(TTA.Palette.paper)
+                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
+                    .onChange(of: cloudflareAccountId) { newValue in
+                        if newValue.isEmpty {
+                            KeychainStore.delete("cloudflareAccountId")
+                        } else {
+                            KeychainStore.set(newValue, forKey: "cloudflareAccountId")
+                        }
+                    }
+
+                SecureField("Cloudflare API token (optional -- pictures)", text: $cloudflareApiToken)
+                    .font(.system(.body, design: .monospaced))
+                    .padding(11)
+                    .background(TTA.Palette.paper)
+                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
+                    .onChange(of: cloudflareApiToken) { newValue in
+                        if newValue.isEmpty {
+                            KeychainStore.delete("cloudflareApiToken")
+                        } else {
+                            KeychainStore.set(newValue, forKey: "cloudflareApiToken")
+                        }
+                    }
+
                 Toggle(
                     "Away-from-home mode",
                     isOn: Binding(
````

- [ ] **Step 2: Build the illustrator and pass it to the library.** Apply this diff to `AppModel.swift`:

````diff
--- a/ios/TinyTalkApp/TinyTalkApp/AppModel.swift
+++ b/ios/TinyTalkApp/TinyTalkApp/AppModel.swift
@@ -485,6 +485,26 @@ final class AppModel: ObservableObject {
         startPollingState()
     }
 
+    /// Storybook pictures away from home need a free Cloudflare account
+    /// (an account id plus an API token, entered in Settings' hidden
+    /// away-from-home card and kept in the Keychain like the Groq key).
+    /// Without BOTH, storybooks are simply text-only -- silently, by design:
+    /// it's an optional extra, not an error.
+    private func makeIllustrator(chat: any ChatCompleting) -> (any StoryIllustrating)? {
+        guard let accountId = KeychainStore.get("cloudflareAccountId"), !accountId.isEmpty,
+              let apiToken = KeychainStore.get("cloudflareApiToken"), !apiToken.isEmpty
+        else { return nil }
+        // Same on-screen debug log as the rest of demo mode -- a bad token
+        // or an exhausted quota shows up there, never in front of the child.
+        return IllustrationPass(
+            chat: chat,
+            backend: CloudflareImageClient(accountId: accountId, apiToken: apiToken),
+            onDebugEvent: { [weak self] line in
+                Task { @MainActor in self?.appendAudioDebugEvent(line) }
+            }
+        )
+    }
+
     /// Away-from-home counterpart to connect() -- builds a DemoConnection
     /// against Groq instead of a WebSocketServerConnection against the
     /// Mac. See the design spec's disclosed simplification: unlike the
@@ -512,7 +532,11 @@ final class AppModel: ObservableObject {
         // One Groq client shared by the live conversation and the storybook
         // rewrite, so both use the same key (and the same free-tier budget).
         let chatClient = GroqChatClient(apiKey: groqKey)
-        let library = DemoStoryLibrary(store: localStoryStore, writer: StorybookWriter(chat: chatClient))
+        let library = DemoStoryLibrary(
+            store: localStoryStore,
+            writer: StorybookWriter(chat: chatClient),
+            illustrator: makeIllustrator(chat: chatClient)
+        )
         let connection = DemoConnection(
             chatClient: chatClient,
             sttClient: GroqWhisperClient(apiKey: groqKey),
````

- [ ] **Step 3: Build the app.**

```bash
xcodebuild -project ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkApp/TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build > /tmp/demo-mode-xcode.txt 2>&1
```
```bash
grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/demo-mode-xcode.txt | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Confirm nothing unintended is staged** (`Local.xcconfig` is gitignored and must not appear):

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 status --short
```

Expected: only ` M ios/TinyTalkApp/TinyTalkApp/AppModel.swift` and ` M ios/TinyTalkApp/TinyTalkApp/SettingsView.swift`.

- [ ] **Step 5: Commit.**

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 add ios/TinyTalkApp/TinyTalkApp/AppModel.swift ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
```
```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 commit -m "feat(ios): away-from-home storybook pictures via Cloudflare, opt-in" -m "Two secure Settings fields (account id, API token) stored in the Keychain like the Groq key. AppModel builds an IllustrationPass only when both are present, so without credentials storybooks stay text-only, silently. Pass diagnostics go to the on-screen debug log."
```

---

### Task 5: Final verification, on-device script, push, draft PR

**Files:** none.

- [ ] **Step 1: Full Swift suite.** Expected `Executed 362 tests, with 0 failures` (Task 3 Step 6's commands; re-run a lone `testPageAudioDittyStopsOnStopPageAudio` failure — known flake).

- [ ] **Step 2: App build.** Expected `** BUILD SUCCEEDED **` (Task 4 Step 3's commands).

- [ ] **Step 3: Exactness check against the verified implementation** (only if the local scratch branch still exists; verify `git rev-parse --verify 62b55d3` first, otherwise skip):

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 diff --ignore-all-space --ignore-blank-lines --stat 62b55d3 HEAD -- ios server
```

Expected: no output.

- [ ] **Step 4: Push and open a DRAFT PR** (never push to `main`; never merge). Mark ready only after the household's on-device pass.

```bash
git -C /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2 push -u origin worktree-demo-mode-phase-2
```

Then `gh pr create --draft --base main` with a body that summarizes the spec's Phase 2, states the test counts, reports the Task 1 Step 7 envelope check (or that it is still pending), and **pastes the on-device script below verbatim**.

- [ ] **Step 5: Hand the household this on-device script.**

**Where the code lives:** `~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/` (branch `worktree-demo-mode-phase-2`).

**Server restart: only for step 3, and only if the Mac is not already running Phase 1's server code.** This phase changes no server code, but the sync step needs Phase 1's `synced_storybook.py` running. If Phase 1 has merged into the checkout your Mac server runs from, nothing to do. Otherwise restart it from a tree that has Phase 1 (this worktree does, once branched from Phase 1):

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/server
```
```bash
~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m tinytalk.app
```

(Make sure Ollama is up first: `ollama serve`, or `curl http://127.0.0.1:11434/` replying `Ollama is running`. This server starts with an empty story library — `server/data/` is gitignored and lives only in the main checkout.)

**iOS rebuild: YES** — `AppModel.swift`, `SettingsView.swift` and the core package changed. Open this worktree's project (not the main checkout's) and Build & Run onto the phone:

```bash
open ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/demo-mode-phase-2/ios/TinyTalkApp/TinyTalkApp.xcodeproj
```

`ios/TinyTalkApp/Local.xcconfig` already exists in this worktree (Preflight created it).

**Getting to the new fields:** open Settings and **long-press the "UNDER THE HOOD" heading for a second**. The debug-log sheet opens (close it) and the hidden **AWAY FROM HOME** card appears below; the two new secure fields are in it, under the Groq and animal-facts keys.

**The script** (Groq key already saved; Cloudflare credentials entered as described; steps 1–2 away from home — phone WiFi off is fine):

1. Away-from-home on. Complete a story (set turns to 4 and pages to 3 first for speed). The End screen waits a little longer than in Phase 1 — the picture pass finishes before "Read it now" un-greys, roughly a minute at most (the 60 s budget is checked before each page, so one slow in-flight picture can run a little over). Then **every page shows a picture**. Note the pictures' style and whether the main character looks like the same character across pages (FLUX.1 [schnell] cannot be given a reference image, so drift is possible; see the spec's risks — report what you see).
2. Start another story and, right after Elsie's closing line, toggle **airplane mode on for a few seconds, then off**. Some pages will have no picture, but the story is readable and no error shows. Open the debug log (long-press "UNDER THE HOOD" again): it has `illustration: page N failed …` and a final `illustration: partial (K/3 pages)` line.
3. Turn away-from-home off, connect to the home server (Phase 1's server code). In the Mac server log you should see `synced storybook accepted for story … : 3 page(s), N image(s)` with N matching the pictures. In the **home** Library, open that story: **the pictures appear** on its pages.
4. Clear both Cloudflare fields (or just one), finish another away story: it is **text-only with no error**. Enter a deliberately wrong API token: the story is text-only and the debug log shows an `illustration: page 0 failed: http(status: 4xx, …` style line (Cloudflare answers a bad token with a 401 or 403) and a final `illustration: failed (0/3 pages)`; nothing appears on screen for the child.

**What a pass looks like:** pictures on every page in step 1; partial pictures and a `partial` log line in step 2; the server's `accepted` line with a non-zero image count and pictures in the home Reading screen in step 3; graceful text-only in step 4.

- [ ] **Step 6: After the household's pass,** mark the PR ready for review, tune `IllustrationPass.styleDirective` / `defaultTimeBudget` if the household asks, and update `CLAUDE.md`'s "Current focus" (demo-mode parity done; issues #24, #26, #33 addressed) in a small follow-up commit.
