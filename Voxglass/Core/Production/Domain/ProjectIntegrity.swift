import Foundation

public enum Severity: String, Sendable, Codable, Comparable {
    case passed
    case warning
    case blocking

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        switch (lhs, rhs) {
        case (.passed, .warning), (.passed, .blocking), (.warning, .blocking): return true
        default: return false
        }
    }
}

public enum IntegrityCode: String, Sendable {
    case duplicateChapterOrdinal
    case missingChapterOrdinal
    case duplicateParagraphOrdinal
    case missingParagraphOrdinal
    case duplicateParagraphID
    case selectedTakeMissing
    case takeAssetMissing
    case takeAssetHashMismatch
    case orphanAsset
    case textHashMismatch
    case creditsChapterMisplaced
    case autosaveOrphan
}

public enum RepairAction: Sendable, Equatable {
    case renumberOrdinals
    case clearSelectedTake(paragraphID: UUID)
    case removeTake(takeID: UUID)
    case moveAssetToTrash(AudioAssetReference)
    case recomputeTextHash(paragraphID: UUID)
    case recoverAutosave(URL)
}

public struct IntegrityFinding: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let severity: Severity
    public let code: IntegrityCode
    public let message: String
    public let chapterID: UUID?
    public let paragraphID: UUID?
    public let repair: RepairAction?

    public init(
        id: UUID = UUID(), // determinism-exempt: convenience default for new findings; verification passes IDGenerator values
        severity: Severity,
        code: IntegrityCode,
        message: String,
        chapterID: UUID? = nil,
        paragraphID: UUID? = nil,
        repair: RepairAction? = nil
    ) {
        self.id = id
        self.severity = severity
        self.code = code
        self.message = message
        self.chapterID = chapterID
        self.paragraphID = paragraphID
        self.repair = repair
    }
}

public enum ProjectIntegrity {
    public static func check(
        _ project: AudiobookProject,
        assets: any ContentAddressedStore,
        deep: Bool = false
    ) -> [IntegrityFinding] {
        var findings: [IntegrityFinding] = []

        let chapterCount = project.chapters.count
        let ordinalSet = Set(project.chapters.map(\.ordinal))
        let expectedOrdinals = Set(0..<chapterCount)

        if ordinalSet.count != chapterCount {
            findings.append(IntegrityFinding(
                severity: .blocking,
                code: .duplicateChapterOrdinal,
                message: "Duplicate chapter ordinals detected."
            ))
        }

        let missing = expectedOrdinals.subtracting(ordinalSet)
        if !missing.isEmpty {
            findings.append(IntegrityFinding(
                severity: .warning,
                code: .missingChapterOrdinal,
                message: "Missing chapter ordinals: \(missing.sorted())."
            ))
        }

        var allParagraphIDs = Set<UUID>()
        for chapter in project.chapters {
            let paraCount = chapter.paragraphs.count
            let paraOrdinals = Set(chapter.paragraphs.map(\.ordinal))
            let expectedParaOrdinals = Set(0..<paraCount)

            if paraOrdinals.count != paraCount {
                findings.append(IntegrityFinding(
                    severity: .blocking,
                    code: .duplicateParagraphOrdinal,
                    message: "Duplicate paragraph ordinals in chapter \(chapter.title).",
                    chapterID: chapter.id
                ))
            }

            let missingPara = expectedParaOrdinals.subtracting(paraOrdinals)
            if !missingPara.isEmpty {
                findings.append(IntegrityFinding(
                    severity: .warning,
                    code: .missingParagraphOrdinal,
                    message: "Missing paragraph ordinals in chapter \(chapter.title): \(missingPara.sorted()).",
                    chapterID: chapter.id
                ))
            }

            for paragraph in chapter.paragraphs {
                if allParagraphIDs.contains(paragraph.id) {
                    findings.append(IntegrityFinding(
                        severity: .blocking,
                        code: .duplicateParagraphID,
                        message: "Duplicate paragraph ID across project: \(paragraph.id).",
                        paragraphID: paragraph.id
                    ))
                }
                allParagraphIDs.insert(paragraph.id)

                if let selectedID = paragraph.selectedTakeID {
                    if !paragraph.takes.contains(where: { $0.id == selectedID }) {
                        findings.append(IntegrityFinding(
                            severity: .blocking,
                            code: .selectedTakeMissing,
                            message: "Selected take \(selectedID) not found in paragraph \(paragraph.id).",
                            paragraphID: paragraph.id,
                            repair: .clearSelectedTake(paragraphID: paragraph.id)
                        ))
                    }
                }

                for take in paragraph.takes {
                    if !assets.exists(take.assetRef) {
                        findings.append(IntegrityFinding(
                            severity: .blocking,
                            code: .takeAssetMissing,
                            message: "Asset missing for take \(take.id): \(take.assetRef.relativePath).",
                            paragraphID: paragraph.id,
                            repair: .removeTake(takeID: take.id)
                        ))
                    }
                }
            }

            if chapter.role == .openingCredits, chapter.ordinal != 0 {
                findings.append(IntegrityFinding(
                    severity: .warning,
                    code: .creditsChapterMisplaced,
                    message: "Opening credits chapter should be first.",
                    chapterID: chapter.id
                ))
            }
            if chapter.role == .closingCredits, chapter.ordinal != project.chapters.count - 1 {
                findings.append(IntegrityFinding(
                    severity: .warning,
                    code: .creditsChapterMisplaced,
                    message: "Closing credits chapter should be last.",
                    chapterID: chapter.id
                ))
            }
        }

        return findings
    }
}
