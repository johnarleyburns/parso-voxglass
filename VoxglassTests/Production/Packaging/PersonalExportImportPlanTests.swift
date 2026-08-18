import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct PersonalExportImportPlanTests {
    @Test func mapsOnlyChapterFilesInProjectOrder() {
        let project = ProjectFixtures.tiny()
        let root = URL(fileURLWithPath: "/tmp/export")
        let copied = URL(fileURLWithPath: "/tmp/copied")
        let chapters = project.chapters.reversed().map { chapter in
            ExportedFile(
                url: root.appendingPathComponent("\(chapter.ordinal + 1)-\(chapter.title).m4a"),
                role: .chapter,
                chapterID: chapter.id,
                duration: Double(chapter.ordinal + 10)
            )
        }
        let wholeBook = ExportedFile(url: root.appendingPathComponent("book.m4b"), role: .secondaryAudio)
        let bundle = ExportBundle(
            destination: .personalMaster,
            rootURL: root,
            files: chapters + [wholeBook],
            checklistURL: root.appendingPathComponent("checklist.md"),
            manifestURL: root.appendingPathComponent("manifest.json"),
            checksumURL: root.appendingPathComponent("checksums.sha256"),
            totalBytes: 0,
            totalDuration: 0
        )

        let plan = PersonalExportImportPlanner().plan(project: project, bundle: bundle, copiedDirectory: copied)
        #expect(plan.count == project.chapters.count)
        #expect(plan.map(\.title) == project.chapters.map(\.title))
        #expect(plan.map(\.sortKey) == project.chapters.map { "\($0.ordinal + 1)-\($0.title).m4a" })
        #expect(plan.allSatisfy { $0.url.deletingLastPathComponent().standardizedFileURL.path == copied.standardizedFileURL.path })
    }
}
