/// Real on-device object classification via Vision's VNClassifyImageRequest
/// -- iOS-only because its public API takes a UIImage, which does not
/// exist on macOS (Vision.framework itself is cross-platform, but that
/// doesn't matter here; see AudioEngine.swift's file-level doc comment
/// for the same #if os(iOS) reasoning applied to a different framework).
/// The confidence-threshold decision itself lives in the pure, tested
/// selectTopClassification (TinyTalkCore/ObjectRecognition.swift) -- this
/// file's only job is mapping VNClassifyImageRequest's real output into
/// that function's plain input type. Not covered by swift test: this
/// project has no TinyTalkPlatformTests target (AudioEngine.swift/
/// VoiceActivityDetector.swift aren't either), and Vision inference can't
/// run in CI regardless -- verified manually on a real device instead
/// (Task 7).
#if os(iOS)
import TinyTalkCore
import UIKit
import Vision

public enum ObjectRecognizerError: Error {
    case noImageData
    case classificationFailed(any Error)
}

public final class VisionObjectRecognizer: @unchecked Sendable {
    /// Starting point per the design spec, not a validated number --
    /// tune against real household objects during on-device testing
    /// (Task 7). Same "reasonable default, easy to retune" treatment as
    /// STORY_TARGET_TURNS/the animal facts confidence choices.
    public static let defaultConfidenceThreshold: Float = 0.3

    private let threshold: Float

    public init(confidenceThreshold: Float = VisionObjectRecognizer.defaultConfidenceThreshold) {
        self.threshold = confidenceThreshold
    }

    /// Runs the classifier entirely on-device (no network call). Returns
    /// nil if nothing clears the confidence threshold or Vision found no
    /// candidates -- treated the same as a thrown error by every caller
    /// in this app (see AppModel.handlePhotoTaken in Task 7): a failed or
    /// ambiguous photo attempt must never block or degrade the core voice
    /// turn, per the design spec's error-handling goal.
    public func recognize(image: UIImage) async throws -> RecognizedObject? {
        guard let cgImage = image.cgImage else {
            throw ObjectRecognizerError.noImageData
        }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ObjectRecognizerError.classificationFailed(error)
        }
        let candidates = (request.results ?? []).map {
            ClassificationCandidate(label: $0.identifier, confidence: $0.confidence)
        }
        return selectTopClassification(candidates, threshold: threshold)
    }
}
#endif
