import Foundation
import Observation
import VoxglassCore

@MainActor
@Observable
public final class SourceImportModel {
    public var extractedDocument: ExtractedDocument?
    public private(set) var isLoading = false
    public private(set) var error: String?
    public var sourceDescription: String = ""
    public private(set) var sourceFormat: SourceFormat?
    public private(set) var sourceFilename: String?
    public private(set) var sourceURL: URL?
    /// Present after a *re*-import (a project with existing chapters): the
    /// reconciliation counts from `ParagraphReidentifier` (§18.1.4, mockup
    /// `19`). Orphans are retired non-destructively (spec §22.6).
    public private(set) var reimportSummary: ReimportSummary?
    /// Segmentation/decoding warnings surfaced at import (§18.1.8, mockup
    /// `03`): "N sections skipped", encoding fallbacks, etc.
    public private(set) var importWarnings: [String] = []

    public var importWarningCount: Int { importWarnings.count }

    public init() {}

    public struct ReimportSummary: Equatable, Sendable {
        public let reused: Int
        public let added: Int
        public let retired: Int
        public let retiredWithRecordings: Int
        public let drifted: Int
        public let orphanChapterID: UUID?

        public init(reused: Int, added: Int, retired: Int, retiredWithRecordings: Int, drifted: Int, orphanChapterID: UUID?) {
            self.reused = reused
            self.added = added
            self.retired = retired
            self.retiredWithRecordings = retiredWithRecordings
            self.drifted = drifted
            self.orphanChapterID = orphanChapterID
        }
    }

    public func importSource(from url: URL, into env: StudioEnvironment) async {
        isLoading = true
        error = nil
        extractedDocument = nil

        do {
            guard let importer = SourceImporterRegistry.importer(for: url) else {
                throw SourceImportError.unsupportedFormat(url.pathExtension)
            }

            let doc = try await importer.extract(from: url)
            self.extractedDocument = doc
            self.sourceDescription = importer.format.rawValue.capitalized
            self.sourceFormat = importer.format
            self.sourceFilename = url.lastPathComponent
            self.sourceURL = url
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func applyToProject(_ env: StudioEnvironment) async {
        guard let project = env.currentProject else { return }

        let segmenter = Segmenter()
        let ids = UUIDGenerator()
        let clock = SystemClock()

        var updated = project
        reimportSummary = nil
        importWarnings = []
        let isReimport = !project.chapters.isEmpty

        if let doc = extractedDocument {
            let result = segmenter.segment(doc, existing: project, ids: ids, clock: clock)
            importWarnings = result.warnings.map(\.message)
            updated.chapters = result.chapters
            updated.modifiedAt = clock.now

            if isReimport, let report = result.reidentification {
                let retiredWithRecordings = report.retiredIDs.filter { id in
                    project.allParagraphs.first { $0.id == id }?.selectedTakeID != nil
                }.count
                reimportSummary = ReimportSummary(
                    reused: report.assignments.count,
                    added: report.newIndices.count,
                    retired: report.retiredIDs.count,
                    retiredWithRecordings: retiredWithRecordings,
                    drifted: report.driftedIDs.count,
                    orphanChapterID: updated.chapters.first { $0.role == .backMatter }?.id
                )
            }

            // §4.7: store the verbatim source in Text/source/<sha>.<ext> and the
            // normalized extracted text in Text/extracted/<sha>.json. Asset
            // persistence is best-effort alongside the store save; a failure
            // must not discard the import.
            if let sourceURL = sourceURL {
                let assets = env.assetStoreForCurrentProject()
                let ext = sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension
                do {
                    let sourceData = try Data(contentsOf: sourceURL)
                    let sourceRef = try await assets.put(sourceData, ext: ext, contentType: "text/plain", subdirectory: .source)
                    let extractedData = try JSONEncoder().encode(ExtractedArchive(document: doc))
                    let extractedRef = try await assets.put(extractedData, ext: "json", contentType: "application/json", subdirectory: .extracted)

                    updated.source = SourceDocument(
                        format: sourceFormat ?? .txt,
                        originalFilename: sourceFilename ?? "source",
                        originalRef: sourceRef,
                        extractedTextRef: extractedRef,
                        textHash: TextNormalizer.hash(doc.plainText),
                        importedAt: clock.now,
                        detectedSectionCount: doc.sections.count,
                        importWarnings: result.warnings
                    )
                } catch {
                    self.error = "Failed to persist source document: \(error.localizedDescription)"
                }
            }
        }

        do {
            try await env.store.save(updated)
            try await env.store.renumberGlobalOrdinals()
            env.setProject(updated)
        } catch {
            self.error = "Failed to persist import: \(error.localizedDescription)"
        }
    }
}

private struct ExtractedArchive: Codable {
    var sections: [ArchivedSection]
    var plainText: String

    init(document: ExtractedDocument) {
        self.sections = document.sections.map { ArchivedSection(heading: $0.heading, blocks: $0.blocks.map {
            ArchivedBlock(kind: $0.kind.rawValue, text: $0.text, start: $0.sourceRange.lowerBound, end: $0.sourceRange.upperBound, headingLevel: $0.headingLevel)
        }) }
        self.plainText = document.plainText
    }
}

private struct ArchivedSection: Codable {
    var heading: String?
    var blocks: [ArchivedBlock]
}

private struct ArchivedBlock: Codable {
    var kind: String
    var text: String
    var start: Int
    var end: Int
    var headingLevel: Int?
}

public enum SourceImportError: LocalizedError {
    case unsupportedFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        }
    }
}

extension SourceImportModel {
    /// Removes the orphaned-recordings chapter after a re-import (mockup
    /// `19`). Retirement stays non-destructive: the audio assets remain in
    /// the store; only the project rows are dropped (§22.6).
    public func discardOrphans(_ env: StudioEnvironment) async {
        guard let summary = reimportSummary,
              let chapterID = summary.orphanChapterID,
              var project = env.currentProject else { return }
        project.chapters.removeAll { $0.id == chapterID }
        do {
            try await env.store.save(project)
            try await env.store.renumberGlobalOrdinals()
            env.setProject(project)
            reimportSummary = nil
        } catch {
            self.error = "Failed to discard orphans: \(error.localizedDescription)"
        }
    }

    public func dismissReimportSummary() {
        reimportSummary = nil
    }

    public func dismissError() {
        error = nil
    }
}
