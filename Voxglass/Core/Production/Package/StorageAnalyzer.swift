import Foundation

public struct StorageReport: Sendable {
    public var originalBytes: Int64
    public var renderBytes: Int64
    public var proxyBytes: Int64
    public var textBytes: Int64
    public var artworkBytes: Int64
    public var exportBytes: Int64
    public var trashBytes: Int64
    public var orphanBytes: Int64
    public var estimatedProjectionBytes: Int64

    public init(
        originalBytes: Int64 = 0,
        renderBytes: Int64 = 0,
        proxyBytes: Int64 = 0,
        textBytes: Int64 = 0,
        artworkBytes: Int64 = 0,
        exportBytes: Int64 = 0,
        trashBytes: Int64 = 0,
        orphanBytes: Int64 = 0,
        estimatedProjectionBytes: Int64 = 0
    ) {
        self.originalBytes = originalBytes
        self.renderBytes = renderBytes
        self.proxyBytes = proxyBytes
        self.textBytes = textBytes
        self.artworkBytes = artworkBytes
        self.exportBytes = exportBytes
        self.trashBytes = trashBytes
        self.orphanBytes = orphanBytes
        self.estimatedProjectionBytes = estimatedProjectionBytes
    }
}

public struct StorageAnalyzer: Sendable {
    public init() {}

    public func report(package: ProjectPackage, project: AudiobookProject) async throws -> StorageReport {
        let store = FileAssetStore(root: package.root)
        let fm = FileManager.default

        var report = StorageReport()

        // References the project actually holds: every take's asset, the
        // source blobs and the cover. Anything else in the asset roots is
        // orphaned (spec §6.5: "assets referenced by nothing").
        var referencedShas = Set<String>()
        for chapter in project.chapters {
            for paragraph in chapter.paragraphs {
                for take in paragraph.takes {
                    referencedShas.insert(take.assetRef.sha256)
                }
            }
        }
        if let source = project.source {
            referencedShas.insert(source.originalRef.sha256)
            referencedShas.insert(source.extractedTextRef.sha256)
        }
        if let cover = project.metadata.coverRef {
            referencedShas.insert(cover.sha256)
        }

        for subdir in AssetSubdirectory.allCases {
            let bytes = try await store.totalBytes(under: subdir)
            switch subdir {
            case .original: report.originalBytes = bytes
            case .render: report.renderBytes = bytes
            case .proxy: report.proxyBytes = bytes
            case .text: report.textBytes += bytes
            case .source: report.textBytes += bytes
            case .extracted: report.textBytes += bytes
            case .artwork: report.artworkBytes = bytes
            }

            if subdir == .original || subdir == .source || subdir == .extracted || subdir == .artwork {
                let refs = try await store.allReferences(under: subdir)
                for ref in refs where !referencedShas.contains(ref.sha256) {
                    report.orphanBytes += Int64(ref.byteCount)
                }
            }
        }

        let exportsDir = package.root.appendingPathComponent("Exports", isDirectory: true)
        if fm.fileExists(atPath: exportsDir.path) {
            report.exportBytes = totalBytesRecursive(at: exportsDir)
        }

        let trashDir = package.root.appendingPathComponent("Trash", isDirectory: true)
        if fm.fileExists(atPath: trashDir.path) {
            report.trashBytes = totalBytesRecursive(at: trashDir)
        }

        let totalDuration = project.chapters.reduce(0.0) { chapterTotal, chapter in
            chapterTotal + chapter.paragraphs.reduce(0.0) { paraTotal, paragraph in
                paraTotal + (paragraph.takes.first { $0.id == paragraph.selectedTakeID }?.duration ?? 0)
            }
        }
        let proxyBitrateKbps = project.profile.proxyBitrateKbps
        report.estimatedProjectionBytes = Int64(totalDuration * Double(proxyBitrateKbps) * 125)

        return report
    }

    private func totalBytesRecursive(at url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) || isDir.boolValue { continue }
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
