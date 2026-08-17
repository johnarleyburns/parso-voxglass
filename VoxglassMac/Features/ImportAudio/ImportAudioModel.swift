import AVFoundation
import Foundation
import Observation
import VoxglassCore

/// Spec §11.5 import of existing audio: decode → silence-based segmentation →
/// paragraph assignment → mandatory origin declaration → one take per segment,
/// each sliced into its own WAV in `Audio/Original`.
@MainActor
@Observable
public final class ImportAudioModel {

    public enum AssignmentMethod: String, CaseIterable, Sendable, Identifiable {
        case sequential
        case splitAcrossChapter
        public var id: String { rawValue }
    }

    public enum OriginChoice: String, CaseIterable, Sendable, Identifiable {
        case importedHuman
        case aiImported
        case unknownImport

        public var id: String { rawValue }

        public var isHuman: Bool { self == .importedHuman }

        /// The spec §11.5 warning shown live whenever a non-human origin is chosen.
        public var warning: String {
            "AI-origin segments make the project ineligible for LibriVox export."
        }

        public var isNonHuman: Bool { !isHuman }
    }

    public struct Segment: Identifiable, Sendable, Equatable {
        public let id: UUID
        public var start: TimeInterval
        public var end: TimeInterval
        public var confidence: SegmentBoundary.Confidence
        public var paragraphID: UUID?

        public var duration: TimeInterval { end - start }
    }

    public private(set) var sourceURL: URL?
    public private(set) var sourceFilename: String?
    public private(set) var segments: [Segment] = []
    public private(set) var sampleRate: Double = 0
    public private(set) var isProcessing = false
    public private(set) var importedTakeCount = 0
    public var error: String?

    public var assignmentMethod: AssignmentMethod = .sequential
    public var origin: OriginChoice?
    public var aiProviderLabel = ""

    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    public let project: AudiobookProject

    public init(
        project: AudiobookProject,
        store: any ProductionStore,
        assets: any ContentAddressedStore
    ) {
        self.project = project
        self.store = store
        self.assets = assets
    }

    public var allParagraphs: [Paragraph] { project.allParagraphs }

    public var originWarning: String? {
        guard let origin, origin.isNonHuman else { return nil }
        return origin.warning
    }

    public var canAssign: Bool {
        guard origin != nil, !segments.isEmpty else { return false }
        return segments.allSatisfy { $0.paragraphID != nil }
    }

    // MARK: - Load and segment

    public func loadFile(at url: URL) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let decoded = try await decode(url)
            sourceURL = url
            sourceFilename = url.lastPathComponent
            sampleRate = decoded.sampleRate
            let segmenter = SilenceSegmenter()
            let options = SilenceSegmenter.Options()
            let regions = segmenter.detect(samples: decoded.samples, sampleRate: decoded.sampleRate, options: options)
            let boundaries = segmenter.proposeBoundaries(regions, boundaryPadding: 0.08, targetCount: nil)
            segments = makeSegments(from: boundaries, duration: decoded.duration)
            error = nil
        } catch {
            segments = []
            self.error = "Failed to load audio: \(error.localizedDescription)"
        }
    }

    private func makeSegments(from boundaries: [SegmentBoundary], duration: TimeInterval) -> [Segment] {
        let times = boundaries.map(\.time).filter { $0 > 0 && $0 < duration }.sorted()
        var result: [Segment] = []
        var cursor: TimeInterval = 0
        for (index, time) in times.enumerated() {
            let confidence = boundaries[index].confidence
            result.append(Segment(id: UUID(), start: cursor, end: time, confidence: confidence, paragraphID: nil))
            cursor = time
        }
        if cursor < duration - 0.001 {
            result.append(Segment(id: UUID(), start: cursor, end: duration, confidence: .review, paragraphID: nil))
        }
        return result
    }

    // MARK: - Assignment

    /// Option 3 (§11.5): detected segments map to paragraphs in order.
    public func assignSequentially(to paragraphIDs: [UUID]) -> Bool {
        guard paragraphIDs.count == segments.count else {
            error = "\(segments.count) segments but \(paragraphIDs.count) paragraphs — adjust the markers first."
            return false
        }
        for i in segments.indices {
            segments[i].paragraphID = paragraphIDs[i]
        }
        error = nil
        return true
    }

    /// Option 2 (§11.5, renamed "Split file across this chapter"): exactly one
    /// segment per paragraph in the chapter. A count mismatch is an error; the
    /// user must adjust markers.
    public func assignSplitAcrossChapter(to paragraphIDs: [UUID]) -> Bool {
        guard paragraphIDs.count == segments.count else {
            error = "\(segments.count) segments but \(paragraphIDs.count) paragraphs in this chapter — adjust the markers before assigning."
            return false
        }
        return assignSequentially(to: paragraphIDs)
    }

    public func clearAssignments() {
        for i in segments.indices {
            segments[i].paragraphID = nil
        }
    }

    // MARK: - Markers (§11.5, F-26)

    /// Test seam: inject a segment layout without decoding a file.
    func setSegmentsForTesting(_ segments: [Segment]) {
        self.segments = segments
    }

    /// Boundary times between segments (the draggable marker positions).
    public var boundaryTimes: [TimeInterval] {
        segments.dropFirst().map(\.start)
    }

    /// Splits the segment containing `time` into two at `time` — the "add
    /// marker" action (`import.audio.addMarker`).
    public func addMarker(at time: TimeInterval) {
        guard let index = segments.firstIndex(where: { $0.start < time && time < $0.end }) else { return }
        let segment = segments[index]
        let first = Segment(id: UUID(), start: segment.start, end: time, confidence: .review, paragraphID: segment.paragraphID)
        let second = Segment(id: UUID(), start: time, end: segment.end, confidence: .review, paragraphID: segment.paragraphID)
        segments.replaceSubrange(index...index, with: [first, second])
    }

    /// Merges the segment at `index` into the previous one by removing the
    /// boundary at its start — the "remove marker" action
    /// (`import.audio.removeMarker`). The first segment has no boundary to
    /// remove.
    public func removeMarker(at segmentIndex: Int) {
        guard segments.indices.contains(segmentIndex), segmentIndex > 0 else { return }
        let prev = segments[segmentIndex - 1]
        let current = segments[segmentIndex]
        let merged = Segment(
            id: UUID(),
            start: prev.start,
            end: current.end,
            confidence: prev.confidence == .high && current.confidence == .high ? .high : .review,
            paragraphID: prev.paragraphID
        )
        segments.replaceSubrange((segmentIndex - 1)...segmentIndex, with: [merged])
    }

    // MARK: - Commit

    /// One take per assigned segment, each sliced into its own WAV in
    /// Audio/Original. The original imported file is retained (spec §11.5);
    /// a "Remove original imported file" action is offered separately.
    public func assignAll() async {
        guard canAssign else {
            error = "Choose an origin and assign every segment before importing."
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let decoded = try await decode(sourceURL!)
            var count = 0
            for segment in segments {
                guard let paragraphID = segment.paragraphID else { continue }
                let sliceURL = try writeSlice(
                    samples: decoded.samples,
                    sampleRate: decoded.sampleRate,
                    startFrame: Int(segment.start * decoded.sampleRate),
                    endFrame: Int(segment.end * decoded.sampleRate)
                )
                let assetRef = try await assets.ingest(
                    fileAt: sliceURL,
                    ext: "wav",
                    contentType: "audio/wav",
                    subdirectory: .original,
                    moving: true
                )
                let origin: AudioOrigin = makeOrigin()
                let paragraph = project.allParagraphs.first { $0.id == paragraphID }
                let take = Take(
                    id: UUID(),
                    paragraphID: paragraphID,
                    assetRef: assetRef,
                    origin: origin,
                    recordedAt: Date(),
                    duration: segment.duration,
                    format: AudioFormatDescription(sampleRate: decoded.sampleRate, channels: 1, bitDepth: 24, codec: "pcm"),
                    textHashAtRecording: paragraph?.textHash ?? ""
                )
                try await store.insertTake(take)
                count += 1
            }
            importedTakeCount = count
        } catch {
            self.error = "Import failed: \(error.localizedDescription)"
        }
    }

    private func makeOrigin() -> AudioOrigin {
        guard let origin else { return .unknownImport(sourceFilename: sourceFilename ?? "unknown") }
        switch origin {
        case .importedHuman:
            return .importedHuman(sourceFilename: sourceFilename ?? "unknown")
        case .aiImported:
            return .aiImported(providerLabel: aiProviderLabel.isEmpty ? "unknown" : aiProviderLabel)
        case .unknownImport:
            return .unknownImport(sourceFilename: sourceFilename ?? "unknown")
        }
    }

    // MARK: - Decode and slice

    private func decode(_ url: URL) async throws -> DecodedAudio {
        try await AVMetricsCalculator().decodeFileForImport(url)
    }

    private func writeSlice(samples: [Float], sampleRate: Double, startFrame: Int, endFrame: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VoxglassImport", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        let lo = max(0, startFrame)
        let hi = min(samples.count, max(lo, endFrame))
        try Self.writePCM24WAV(to: url, samples: samples[lo..<hi], sampleRate: sampleRate)
        return url
    }

    /// 24-bit little-endian PCM WAV, mono, native rate.
    static func writePCM24WAV(to url: URL, samples: ArraySlice<Float>, sampleRate: Double) throws {
        let frameCount = samples.count
        var data = Data(capacity: 44 + frameCount * 3)

        func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let dataSize = frameCount * 3
        append(Array("RIFF".utf8)); le32(UInt32(36 + dataSize))
        append(Array("WAVE".utf8))
        append(Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 3)); le16(3); le16(24)
        append(Array("data".utf8)); le32(UInt32(dataSize))

        for sample in samples {
            let value = Int32((Double(sample) * 8_388_607.0).rounded())
            let clamped = max(-8_388_608, min(8_388_607, value))
            let u = UInt32(bitPattern: clamped)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8((u >> 8) & 0xFF))
            data.append(UInt8((u >> 16) & 0xFF))
        }
        try data.write(to: url, options: .atomic)
    }
}
