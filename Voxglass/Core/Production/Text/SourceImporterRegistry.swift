import Foundation
import UniformTypeIdentifiers

public struct SourceImporterRegistry: Sendable {
    public static let all: [any SourceImporting] = [
        EPUBImporter(), DOCXImporter(), MarkdownImporter(), TXTImporter()
    ]

    public static func importer(for url: URL) -> (any SourceImporting)? {
        if let utType = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
           let ut = UTType(utType) {
            if ut.conforms(to: .epub) { return EPUBImporter() }
            if ut.conforms(to: UTType("org.openxmlformats.wordprocessingml.document") ?? .data) { return DOCXImporter() }
        }

        for importer in all {
            if importer.canImport(url) { return importer }
        }

        // §9.1: fall back to content sniffing so extensionless or mislabeled
        // files still import.
        return sniff(url)
    }

    private static func sniff(_ url: URL) -> (any SourceImporting)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 4), header.count == 4 else { return nil }
        let isZIP = header == Data([0x50, 0x4B, 0x03, 0x04]) || header == Data([0x50, 0x4B, 0x05, 0x06])

        if isZIP {
            // Distinguish EPUB from DOCX by looking for META-INF/container.xml
            // vs word/document.xml in the central directory.
            if let whole = try? Data(contentsOf: url) {
                let ns = String(data: whole, encoding: .utf8) ?? ""
                if ns.contains("META-INF/container.xml") { return EPUBImporter() }
                if ns.contains("word/document.xml") { return DOCXImporter() }
            }
        }

        // Text: sniff for Markdown markers.
        if let sample = try? handle.read(upToCount: 8 * 1024),
           let text = String(data: sample, encoding: .utf8) {
            if text.contains("---") || text.contains("#") { return MarkdownImporter() }
            return TXTImporter()
        }

        return nil
    }
}
