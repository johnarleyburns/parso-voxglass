import Foundation

/// How a large audio file is assigned to paragraphs (spec §10).
public enum AudioImportMode: String, Codable, Sendable, CaseIterable {
    /// Split the file across a chapter by silence markers, then match the
    /// detected segments to paragraphs in document order (mockup 07 default).
    case splitBySilence
    /// Assign detected segments sequentially; the user confirms each boundary.
    case sequential
    /// One paragraph, whole file — for a single poem or a pickup.
    case wholeParagraph
}

/// One slice of an imported file, expressed in **source-file** sample frames,
/// with the paragraph it is assigned to (nil when the slice is unmatched).
public struct ImportedSlice: Sendable, Equatable, Identifiable {
    public var id: Int
    public var startFrame: Int
    public var frameCount: Int
    public var paragraphID: UUID?

    public init(id: Int, startFrame: Int, frameCount: Int, paragraphID: UUID? = nil) {
        self.id = id
        self.startFrame = startFrame
        self.frameCount = frameCount
        self.paragraphID = paragraphID
    }

    public var duration: TimeInterval? { nil } // duration derived by the caller from sampleRate
}

/// The assignment plan for one imported file: the slices the file is cut into
/// and which paragraphs they map to. Pure planning — the importer executes it.
public struct AudioImportPlan: Sendable, Equatable {
    public var mode: AudioImportMode
    public var slices: [ImportedSlice]
    /// Detected segments that could not be matched to a paragraph (more
    /// segments than targets in auto modes).
    public var unmatchedSliceCount: Int
    /// True when every slice was assigned to a paragraph.
    public var isFullyAssigned: Bool { unmatchedSliceCount == 0 && !slices.isEmpty }

    public init(mode: AudioImportMode, slices: [ImportedSlice], unmatchedSliceCount: Int) {
        self.mode = mode
        self.slices = slices
        self.unmatchedSliceCount = unmatchedSliceCount
    }
}

/// Turns decoded PCM and the chosen assignment mode into a slice-to-paragraph
/// plan (§10). Pure: no file access, deterministic, testable on any platform.
public struct AudioImportPlanner: Sendable {

    public init() {}

    public func plan(
        samples: [Float],
        sampleRate: Double,
        mode: AudioImportMode,
        targetParagraphIDs: [UUID]
    ) -> AudioImportPlan {
        switch mode {
        case .wholeParagraph:
            return wholeFilePlan(samples: samples, sampleRate: sampleRate, target: targetParagraphIDs.first)
        case .splitBySilence, .sequential:
            return silencePlan(samples: samples, sampleRate: sampleRate, mode: mode, targets: targetParagraphIDs)
        }
    }

    private func wholeFilePlan(samples: [Float], sampleRate: Double, target: UUID?) -> AudioImportPlan {
        let slice = ImportedSlice(id: 0, startFrame: 0, frameCount: samples.count, paragraphID: target)
        return AudioImportPlan(mode: .wholeParagraph, slices: [slice], unmatchedSliceCount: target == nil ? 1 : 0)
    }

    private func silencePlan(
        samples: [Float],
        sampleRate: Double,
        mode: AudioImportMode,
        targets: [UUID]
    ) -> AudioImportPlan {
        let duration = Double(samples.count) / max(1, sampleRate)
        let regions = SilenceSegmenter().detect(samples: samples, sampleRate: sampleRate)

        // Speech regions are the gaps between detected silences: leading and
        // trailing silence are dropped, and the file is covered by the spans
        // that remain. This is the same analysis the assembly trim uses —
        // detected, never guessed (mockup 07 "uses the same analysis as import").
        var ranges: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for region in regions where region.endTime <= duration && region.startTime >= cursor {
            if region.startTime > cursor {
                ranges.append((cursor, region.startTime))
            }
            cursor = region.endTime
        }
        if cursor < duration {
            ranges.append((cursor, duration))
        }

        var slices: [ImportedSlice] = []
        for (index, range) in ranges.enumerated() {
            let startFrame = Int(range.start * sampleRate)
            let frameCount = Int((range.end - range.start) * sampleRate)
            guard frameCount > 0 else { continue }
            slices.append(ImportedSlice(id: index, startFrame: startFrame, frameCount: frameCount))
        }

        var assigned = 0
        for index in slices.indices where index < targets.count {
            slices[index].paragraphID = targets[index]
            assigned += 1
        }

        let unmatched = max(0, slices.count - assigned)
        return AudioImportPlan(mode: mode, slices: slices, unmatchedSliceCount: unmatched)
    }
}
