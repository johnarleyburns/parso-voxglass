import Foundation
import PDFKit

/// Extracts the selectable text embedded in a PDF. Each PDF page becomes a
/// playback chapter, which makes long opinions practical to resume and keeps
/// the Read with AI storage model identical to EPUB imports.
public struct PDFImporter: SourceImporting {
    public let format: SourceFormat = .pdf

    public init() {}

    public func canImport(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    public func extract(from url: URL) async throws -> ExtractedDocument {
        guard let pdf = PDFDocument(url: url) else {
            return unreadableDocument(for: url, message: "Not a valid PDF document.")
        }

        var sections: [ExtractedSection] = []
        var plainTextParts: [String] = []
        var warnings: [ImportWarning] = []
        var sourceOffset = 0

        for pageIndex in 0..<pdf.pageCount {
            let text = pdf.page(at: pageIndex)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                warnings.append(ImportWarning(
                    kind: .imageOnlyContent,
                    message: "Page \(pageIndex + 1) does not contain selectable text.",
                    paragraphIndex: pageIndex
                ))
                continue
            }

            let block = ExtractedBlock(
                kind: .paragraph,
                text: text,
                sourceRange: sourceOffset..<(sourceOffset + text.count)
            )
            sections.append(ExtractedSection(
                heading: "Page \(pageIndex + 1)",
                blocks: [block],
                sourceStart: sourceOffset
            ))
            plainTextParts.append(text)
            sourceOffset += text.count + 2
        }

        return ExtractedDocument(
            sections: sections,
            title: metadataString(pdf, key: .titleAttribute) ?? url.deletingPathExtension().lastPathComponent,
            author: metadataString(pdf, key: .authorAttribute),
            warnings: warnings,
            plainText: plainTextParts.joined(separator: "\n\n")
        )
    }

    private func metadataString(_ pdf: PDFDocument, key: PDFDocumentAttribute) -> String? {
        guard let value = pdf.documentAttributes?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func unreadableDocument(for url: URL, message: String) -> ExtractedDocument {
        ExtractedDocument(
            title: url.deletingPathExtension().lastPathComponent,
            warnings: [ImportWarning(kind: .emptySection, message: message)]
        )
    }
}
