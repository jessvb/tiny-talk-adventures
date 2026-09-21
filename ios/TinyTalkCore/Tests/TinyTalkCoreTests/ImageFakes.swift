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
