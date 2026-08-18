import Foundation

/// Maps a completed personal-listening package to the chapter files registered
/// in My Books. Whole-book M4B, masters, reports, and artwork are deliberately
/// excluded even when a transcoder returns a generic audio role.
public struct PersonalExportImportPlanner: Sendable {
    public init() {}

    public func plan(
        project: AudiobookProject,
        bundle: ExportBundle,
        copiedDirectory: URL
    ) -> [LocalAudioImport] {
        bundle.files
            .filter { $0.role == .chapter }
            .sorted { lhs, rhs in
                let left = chapterOrdinal(for: lhs, in: project)
                let right = chapterOrdinal(for: rhs, in: project)
                if left != right { return left < right }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            .map { file in
                let chapter = file.chapterID.flatMap { id in project.chapters.first { $0.id == id } }
                return LocalAudioImport(
                    url: copiedDirectory.appendingPathComponent(file.url.lastPathComponent),
                    title: chapter?.title ?? file.url.deletingPathExtension().lastPathComponent,
                    sortKey: file.url.lastPathComponent,
                    duration: file.duration
                )
            }
    }

    private func chapterOrdinal(for file: ExportedFile, in project: AudiobookProject) -> Int {
        guard let chapterID = file.chapterID,
              let chapter = project.chapters.first(where: { $0.id == chapterID }) else {
            return .max
        }
        return chapter.ordinal
    }
}
