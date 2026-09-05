/// Pure, cross-platform half of on-device object recognition -- the
/// confidence-threshold decision, with no dependency on Vision or
/// UIImage (both iOS-only / TinyTalkPlatform-only). See
/// TinyTalkPlatform/ObjectRecognizer.swift for the Vision-framework
/// wrapper that calls into this. Mirrors
/// server/tinytalk/object_recognition.py conceptually (deterministic,
/// no I/O) though the two don't share a protocol -- the server only
/// ever sees the final label, never candidate scores.
import Foundation

public struct ClassificationCandidate: Sendable, Equatable {
    public let label: String
    public let confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

public struct RecognizedObject: Sendable, Equatable {
    public let label: String
    public let confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

/// ImageNet-1000 classifiers (e.g. FastViT) ship class labels as raw,
/// comma-separated WordNet synonym lists -- "teddy, teddy bear",
/// "studio couch, day bed" -- rather than a single clean noun, unlike
/// VNClassifyImageRequest's own taxonomy (already single terms). Takes
/// the first (canonical WordNet) synonym; it doesn't need to be the most
/// colloquial phrasing since the LLM has creative license to reinterpret
/// it anyway (see the object-recognition design spec's weave-in
/// guidance). Falls back to the original string if it's empty (no
/// comma-separated first component to take).
public func primaryLabel(from rawIdentifier: String) -> String {
    let first = rawIdentifier.split(separator: ",", maxSplits: 1).first.map(String.init) ?? rawIdentifier
    return first.trimmingCharacters(in: .whitespaces)
}

/// Picks the highest-confidence candidate, if any clears `threshold`.
/// candidates is expected in Vision's own already-sorted (descending
/// confidence) order, but this does not assume that -- it scans for the
/// max explicitly, keeping the FIRST-seen candidate on an exact tie
/// (see testTiesKeepWhicheverCandidateVisionRankedFirst).
public func selectTopClassification(
    _ candidates: [ClassificationCandidate], threshold: Float
) -> RecognizedObject? {
    guard var best = candidates.first else { return nil }
    for candidate in candidates.dropFirst() where candidate.confidence > best.confidence {
        best = candidate
    }
    guard best.confidence >= threshold else { return nil }
    return RecognizedObject(label: best.label, confidence: best.confidence)
}
