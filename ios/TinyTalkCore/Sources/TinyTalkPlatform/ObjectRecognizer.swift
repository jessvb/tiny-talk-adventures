/// Real on-device object classification via a bundled FastViT-T8 Core ML
/// model -- Apple's own ImageNet-1000 classifier, chosen over the
/// previous VNClassifyImageRequest (Apple's built-in ~1300-category
/// taxonomy) because real on-device testing showed that taxonomy's
/// labels were too generic or too rarely confident on real household
/// objects. iOS-only because its public API takes a UIImage, which does
/// not exist on macOS (Vision.framework itself is cross-platform, but
/// that doesn't matter here; see AudioEngine.swift's file-level doc
/// comment for the same #if os(iOS) reasoning applied to a different
/// framework). The confidence-threshold decision itself lives in the
/// pure, tested selectTopClassification (TinyTalkCore/
/// ObjectRecognition.swift) -- this file's only job is mapping
/// VNCoreMLRequest's real output into that function's plain input type.
/// Not covered by swift test: this project has no TinyTalkPlatformTests
/// target (AudioEngine.swift/VoiceActivityDetector.swift aren't either),
/// and Vision/Core ML inference can't run in CI regardless -- verified
/// manually on a real device instead.
///
/// The model ships as a pre-compiled .mlmodelc under Resources/ (see
/// Package.swift) rather than the raw .mlpackage Apple distributes --
/// unlike an Xcode app target, SwiftPM's resource pipeline does not run
/// a downloaded .mlpackage through the Core ML compiler or generate a
/// typed Swift wrapper class for it, so this loads it the fully dynamic
/// way (Bundle.module + MLModel(contentsOf:)) instead of referencing a
/// generated `FastViTT8F16` type the way an app-target model would.
#if os(iOS)
import CoreML
import TinyTalkCore
import UIKit
import Vision

public enum ObjectRecognizerError: Error {
    case noImageData
    case modelUnavailable(any Error)
    case classificationFailed(any Error)
}

public final class VisionObjectRecognizer: @unchecked Sendable {
    /// Starting point, not a validated number -- tune against real
    /// household objects during on-device testing. Not comparable to the
    /// old VNClassifyImageRequest-era default: that request's calibrated
    /// hasMinimumPrecision/hasMinimumRecall filter is gone (a generic
    /// downloaded classifier carries no such calibration data), replaced
    /// by a flat confidence cutoff over FastViT's raw softmax output,
    /// which sits on its own scale. Same "reasonable default, easy to
    /// retune" treatment as STORY_TARGET_TURNS/the animal facts
    /// confidence choices.
    public static let defaultConfidenceThreshold: Float = 0.5

    private let threshold: Float
    /// Loaded once at init and reused for every recognize() call --
    /// unlike VNClassifyImageRequest (a stateless built-in request type),
    /// a Core ML model is a real loaded asset worth paying for exactly
    /// once, not per photo. Stored as a Result rather than throwing from
    /// init so the existing non-throwing `VisionObjectRecognizer()` call
    /// site (AppModel's stored property) doesn't need to change; a load
    /// failure instead surfaces the first time recognize() is called.
    private let modelResult: Result<VNCoreMLModel, Error>

    public init(confidenceThreshold: Float = VisionObjectRecognizer.defaultConfidenceThreshold) {
        self.threshold = confidenceThreshold
        self.modelResult = Result { try Self.loadModel() }
    }

    private static func loadModel() throws -> VNCoreMLModel {
        // Force-unwrapped: a missing bundled resource is a packaging bug
        // caught immediately by any build/run, not a runtime condition
        // this app needs to recover from -- matches how Xcode's own
        // generated Core ML wrapper classes look this up internally.
        let modelURL = Bundle.module.url(forResource: "FastViTT8F16", withExtension: "mlmodelc")!
        let mlModel = try MLModel(contentsOf: modelURL, configuration: MLModelConfiguration())
        return try VNCoreMLModel(for: mlModel)
    }

    /// Runs the classifier entirely on-device (no network call). Returns
    /// nil if nothing clears the confidence threshold or the model found
    /// no candidates -- treated the same as a thrown error by every
    /// caller in this app (see AppModel.handlePhotoTaken): a failed or
    /// ambiguous photo attempt must never block or degrade the core voice
    /// turn, per the design spec's error-handling goal.
    public func recognize(image: UIImage) async throws -> RecognizedObject? {
        guard let cgImage = image.cgImage else {
            throw ObjectRecognizerError.noImageData
        }
        let model: VNCoreMLModel
        do {
            model = try modelResult.get()
        } catch {
            throw ObjectRecognizerError.modelUnavailable(error)
        }
        let request = VNCoreMLRequest(model: model)
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ObjectRecognizerError.classificationFailed(error)
        }
        // FastViT (like any generic downloaded Core ML classifier) has no
        // calibration data, so unlike the old hasMinimumPrecision-based
        // filter this is a flat confidence >= threshold cutoff, applied
        // by selectTopClassification itself. ImageNet-1000 class labels
        // also come back as raw comma-separated WordNet synonym lists
        // (e.g. "teddy, teddy bear", "studio couch, day bed") rather than
        // a single clean noun -- primaryLabel(from:) takes the first,
        // canonical synonym; the LLM has creative license to reinterpret
        // it either way (see the design spec's weave-in guidance), so
        // exact colloquial phrasing doesn't matter here.
        let candidates = ((request.results as? [VNClassificationObservation]) ?? [])
            .map { ClassificationCandidate(label: primaryLabel(from: $0.identifier), confidence: $0.confidence) }
        return selectTopClassification(candidates, threshold: threshold)
    }
}
#endif
