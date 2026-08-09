import Foundation

/// The export preflight output (§13.2): what must hydrate from iCloud, how much
/// staging space the scope needs vs what is free, and which selected takes have
/// never verified against iCloud. The Validation screen and the export wizard
/// both consume it; the rule engine turns it into the four §12.2 issue codes.
public struct ExportPreflightResult: Sendable, Equatable {
    /// Bytes and asset ids of selected-take audio that live only in iCloud.
    public let hydrationPlan: ProductionHydrationPlan
    /// Chapters (in scope) whose selected takes must hydrate — display count.
    public let remoteHydrationChapterCount: Int
    /// Estimated staging bytes the export needs free on the working volume.
    public let storageRequiredBytes: Int64
    /// Bytes currently available on the working volume (0 when unknown).
    public let storageAvailableBytes: Int64
    /// SHA-256 of selected takes whose assets are still `.localOnly`.
    public let unverifiedSelectedTakeHashes: Set<String>

    /// The context shape the rule engine consumes.
    public var exportPreflightContext: ExportPreflightContext {
        ExportPreflightContext(
            remoteHydrationBytes: hydrationPlan.byteCount,
            remoteHydrationChapterCount: remoteHydrationChapterCount,
            storageRequiredBytes: storageRequiredBytes,
            storageAvailableBytes: storageAvailableBytes,
            unverifiedSelectedTakeHashes: unverifiedSelectedTakeHashes
        )
    }

    public init(
        hydrationPlan: ProductionHydrationPlan,
        remoteHydrationChapterCount: Int,
        storageRequiredBytes: Int64,
        storageAvailableBytes: Int64,
        unverifiedSelectedTakeHashes: Set<String>
    ) {
        self.hydrationPlan = hydrationPlan
        self.remoteHydrationChapterCount = remoteHydrationChapterCount
        self.storageRequiredBytes = storageRequiredBytes
        self.storageAvailableBytes = storageAvailableBytes
        self.unverifiedSelectedTakeHashes = unverifiedSelectedTakeHashes
    }
}

/// Pure preflight planner (§13.2). The app feeds the current `ProductionAssetRecord`
/// set from the project's `production_asset` table and the volume's free bytes;
/// everything else is derived from the project graph so it stays testable.
public enum ExportPreflight {

    /// Computes the preflight for `scope` on `project`.
    ///
    /// - Parameters:
    ///   - assets: the project's `ProductionAssetRecord` rows, used to decide
    ///     remote-only vs local vs unverified for each selected take.
    ///   - freeBytes: bytes available on the volume that will hold the staging;
    ///     nil (unknown) reports 0 available, which a caller may treat as
    ///     "cannot confirm enough space".
    public static func compute(
        project: AudiobookProject,
        assets: [ProductionAssetRecord],
        scope: ExportScope,
        freeBytes: Int64?
    ) -> ExportPreflightResult {
        let chapters = PackagingSupport.chapters(in: project, scope: scope)
        let recordByHash = Dictionary(
            assets.map { ($0.sha256, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var selectedRecords: [ProductionAssetRecord] = []
        var unverifiedHashes: Set<String> = []
        var storageRequired: Int64 = 0
        var remoteChapterIDs = Set<UUID>()

        for chapter in chapters {
            for paragraph in chapter.paragraphs {
                guard let selected = paragraph.selectedTakeID,
                      let take = paragraph.takes.first(where: { $0.id == selected }) else { continue }
                storageRequired += Int64(take.assetRef.byteCount)
                guard let record = recordByHash[take.assetRef.sha256] else { continue }
                if record.state == .remoteOnly || record.state == .missing {
                    selectedRecords.append(record)
                    remoteChapterIDs.insert(record.chapterID ?? chapter.id)
                } else if record.state == .localOnly {
                    unverifiedHashes.insert(record.sha256)
                }
            }
        }

        let plan = ProductionHydrationPlanner().plan(for: selectedRecords, purpose: .exportStaging)
        return ExportPreflightResult(
            hydrationPlan: plan,
            remoteHydrationChapterCount: remoteChapterIDs.count,
            storageRequiredBytes: storageRequired,
            storageAvailableBytes: freeBytes ?? 0,
            unverifiedSelectedTakeHashes: unverifiedHashes
        )
    }
}
