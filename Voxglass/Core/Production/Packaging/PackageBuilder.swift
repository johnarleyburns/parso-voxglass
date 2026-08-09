import Foundation

// MARK: - PackagingError

public enum PackagingError: Error, Sendable, Equatable {
    /// The project is ineligible for this destination (§16.4 precondition 1).
    /// LibriVox carries `LegalStrings.librivoxHumanOnly` as its reason.
    case ineligible(DestinationID, reason: String)
    /// Validation for the destination has blocking issues that must be fixed
    /// before packaging (§16.1 "stop on blocking").
    case blockingIssues([ValidationIssue])
    /// The destination's codec is not available on this build (§16.3). Checked
    /// BEFORE any file is written.
    case encoderUnavailable(String)
    /// A required piece of project state is missing (identifier, retail sample…).
    case projectNotReady(String)
}

// MARK: - PackageBuilder

/// Produces a submission package for one destination (§16.1, §16.4–16.9).
///
/// The pipeline is: validate (blocking → stop) → render lossless chapter
/// masters → transcode to the destination format → tag → name → write
/// artifacts → checksums → checklist. Each step is cancellable and reports
/// per-file progress through `progress`.
public protocol PackageBuilder: Sendable {
    var destination: DestinationID { get }

    func build(
        project: AudiobookProject,
        renders: any ChapterRenderable,
        transcoder: any AudioTranscoding,
        assets: any ContentAddressedStore,
        into exportsRoot: URL,
        options: ExportOptions,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> ExportBundle
}

// MARK: - Shared helpers for builders

/// Cross-builder utilities: directory layout, validation preconditions, and
/// deterministic JSON. Builders share these so the packaging layer has one
/// place where destination constants could live (gate G-10: none do — all
/// destination numbers come from `DestinationProfile`).
public enum PackagingSupport {

    /// The machine-readable manifest encoder: sorted keys, ISO-8601 dates,
    /// compact separators — byte-for-byte deterministic output.
    public static func deterministicJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    /// The per-chapter render plan for `chapterID` at the render sample rate
    /// (§12.4). The renderer always works in float PCM; the destination
    /// format is applied by the transcoder afterward.
    public static func renderPlan(
        for chapter: ProductionChapter,
        in project: AudiobookProject,
        sampleRate: Double = 44_100
    ) -> RenderPlan {
        let settings = project.profile.assembly
        let segments = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: settings)
        let format = AudioSpec(container: .caf, codec: .pcm, sampleRate: sampleRate, channels: 1, bitDepth: 32)
        let key = RenderCacheKey.key(chapterID: chapter.id, segments: segments, settings: settings, format: format)
        return RenderPlan(chapterID: chapter.id, segments: segments, settings: settings, outputFormat: format, cacheKey: key)
    }

    /// The chapters covered by `options.scope`, in document order.
    public static func chapters(in project: AudiobookProject, scope: ExportScope) -> [ProductionChapter] {
        switch scope {
        case .wholeBook:
            return project.chapters
        case .chapters(let ids):
            let set = Set(ids)
            return project.chapters.filter { set.contains($0.id) }
        }
    }

    /// Collects metrics for every selected take, keyed by take ID — the shape
    /// `ValidationRuleEngine.evaluate` expects (see `ValidationModel.evaluate`).
    public static func selectedTakeMetrics(_ project: AudiobookProject) -> [UUID: AudioQualityMetrics] {
        var metrics: [UUID: AudioQualityMetrics] = [:]
        for paragraph in project.allParagraphs {
            guard let sid = paragraph.selectedTakeID,
                  let take = paragraph.takes.first(where: { $0.id == sid }),
                  let takeMetrics = take.metrics else { continue }
            metrics[take.id] = takeMetrics
        }
        return metrics
    }

    /// Runs the pure rule engine for `profile` and returns blocking issues.
    /// Builders call this to satisfy the "stop on blocking" precondition.
    public static func blockingIssues(
        for project: AudiobookProject,
        profile: DestinationProfile,
        context: ValidationContext = ValidationContext()
    ) -> [ValidationIssue] {
        let issues = ValidationRuleEngine().evaluate(
            project: project,
            metrics: selectedTakeMetrics(project),
            profile: profile,
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly,
            context: context
        )
        return issues.filter { $0.severity == .blocking }
    }

    /// A hyphen-separated directory slug ("The Murder of Roger Ackroyd" →
    /// `the-murder-of-roger-ackroyd`), used for export directory names.
    public static func directorySlug(_ raw: String) -> String {
        let deaccented = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let lower = deaccented.lowercased()
        var pieces: [String] = []
        var current = ""
        for scalar in lower.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { pieces.append(current); current = "" }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces.isEmpty ? "book" : pieces.joined(separator: "-")
    }

    /// Formats a duration as `MM:SS`, or `H:MM:SS` at 1 hour+ — the format the
    /// LibriVox forum post and the archive manifest use.
    public static func clockTime(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// A deterministic byte-count label ("3.4 GB", "512 MB") for preflight
    /// messages and export summaries. Locale-independent so reports are stable.
    public static func formattedBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", b / 1024 / 1024 / 1024)
        }
        if b >= 1024 * 1024 {
            return String(format: "%.0f MB", b / 1024 / 1024)
        }
        if b >= 1024 {
            return String(format: "%.0f KB", b / 1024)
        }
        return "\(bytes) B"
    }

    /// The output directory a builder writes into for `destination` — the one
    /// source of truth shared by the builders and `ResumableExportRunner`, so a
    /// resumed run reopens exactly the staging the builders produced.
    public static func exportDirectory(
        for destination: DestinationID,
        project: AudiobookProject,
        exportsRoot: URL
    ) -> URL {
        switch destination {
        case .librivox:
            return exportsRoot
                .appendingPathComponent("LibriVox", isDirectory: true)
                .appendingPathComponent(directorySlug(project.metadata.title), isDirectory: true)
        case .internetArchive:
            let identifier = project.metadata.archiveIdentifier ?? "book"
            return exportsRoot
                .appendingPathComponent("InternetArchive", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
        default:
            return exportsRoot
                .appendingPathComponent(destination.rawValue.capitalized, isDirectory: true)
        }
    }
}
