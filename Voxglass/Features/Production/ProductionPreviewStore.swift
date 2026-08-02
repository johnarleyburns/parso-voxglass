import Foundation
import Observation
import VoxglassCore

/// The phone's local cache of production previews (spec §18.2.8): one JSON
/// snapshot per project in `Application Support/Productions/<projectID>/` plus
/// proxy audio in `…/proxies/<paragraphID>.m4a`. No CloudKit here — this store is
/// fed by `PhoneProductionSync`.
@MainActor
@Observable
public final class ProductionPreviewStore {

    public private(set) var projections: [SyncProjection] = []
    public private(set) var lastReceivedDate: Date?
    public private(set) var downloadedBytes: Int64 = 0

    private let baseDirectory: URL

    public init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? ProductionPreviewStore.defaultBaseDirectory()
    }

    public func load() async {
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let urls = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [SyncProjection] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let projection = try? JSONDecoder().decode(SyncProjection.self, from: data) else { continue }
            loaded.append(projection)
        }
        projections = loaded.sorted { $0.project.title < $1.project.title }
        await refreshDownloadedBytes()
    }

    public func projection(id: UUID) -> SyncProjection? {
        projections.first { $0.project.id == id }
    }

    public func summaries() -> [ProjectSummary] {
        projections.map(\.project)
    }

    public func apply(_ projection: SyncProjection) async {
        let directory = directory(for: projection.project.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(projection) {
            try? data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        }
        if !projections.contains(where: { $0.project.id == projection.project.id }) {
            projections.append(projection)
        } else if let index = projections.firstIndex(where: { $0.project.id == projection.project.id }) {
            projections[index] = projection
        }
        projections.sort { $0.project.title < $1.project.title }
        lastReceivedDate = Date()
    }

    public func remove(projectID: UUID) async {
        projections.removeAll { $0.project.id == projectID }
        try? FileManager.default.removeItem(at: directory(for: projectID))
        await refreshDownloadedBytes()
    }

    public func saveProxy(data: Data, paragraphID: UUID, projectID: UUID) async {
        let proxies = directory(for: projectID).appendingPathComponent("proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: proxies, withIntermediateDirectories: true)
        let url = proxies.appendingPathComponent("\(paragraphID.uuidString).m4a")
        try? data.write(to: url, options: .atomic)
        await refreshDownloadedBytes()
    }

    public func proxyURL(paragraphID: UUID, projectID: UUID) -> URL? {
        let url = directory(for: projectID).appendingPathComponent("proxies/\(paragraphID.uuidString).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func removeDownloadedAudio(projectID: UUID) async {
        let proxies = directory(for: projectID).appendingPathComponent("proxies", isDirectory: true)
        try? FileManager.default.removeItem(at: proxies)
        await refreshDownloadedBytes()
    }

    public func paragraphs(projectID: UUID, predicate: ReviewPredicate) -> [ParagraphProjection] {
        guard let projection = projection(id: projectID) else { return [] }
        switch predicate {
        case .flagged:
            return projection.paragraphs.filter { $0.reviewState == .flagged }
        case .needsPickup:
            return projection.paragraphs.filter { $0.reviewState == .needsPickup }
        case .unapproved:
            return projection.paragraphs.filter { $0.reviewState != .approved && $0.takeID != nil }
        case .unreviewed:
            return projection.paragraphs.filter { $0.reviewState == .unreviewed }
        case .allRecorded:
            return projection.paragraphs.filter { $0.takeID != nil }
        case .selectedParagraphs(let ids):
            return projection.paragraphs.filter { ids.contains($0.id) }
        case .chapter(let chapterID):
            return projection.paragraphs.filter { $0.chapterID == chapterID }
        case .tag(let tag):
            return projection.paragraphs.filter { $0.latestNoteTag == tag }
        }
    }

    // MARK: - Internals

    private func directory(for projectID: UUID) -> URL {
        baseDirectory.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func refreshDownloadedBytes() async {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var total: Int64 = 0
        for url in urls where url.pathExtension == "json" {
            let proxyDir = url.deletingLastPathComponent().appendingPathComponent("proxies", isDirectory: true)
            if let files = try? FileManager.default.contentsOfDirectory(at: proxyDir, includingPropertiesForKeys: keys) {
                for file in files {
                    total += (try? file.resourceValues(forKeys: Set(keys)).fileSize).map(Int64.init) ?? 0
                }
            }
        }
        downloadedBytes = total
    }

    private static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("Productions", isDirectory: true)
    }
}
