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

    /// The bundle's cover image, remapped into `copiedDirectory` the same
    /// way `plan(...)` remaps chapter files — nil if the export has none.
    /// Not wired into `plan(...)` itself (which only ever returns chapter
    /// audio, by design), since the cover isn't a `LocalAudioImport`; the
    /// caller passes this straight through to `importLocalFolder`'s own
    /// `coverURL` parameter instead.
    public func coverURL(bundle: ExportBundle, copiedDirectory: URL) -> URL? {
        bundle.files.first { $0.role == .cover }
            .map { copiedDirectory.appendingPathComponent($0.url.lastPathComponent) }
    }

    private func chapterOrdinal(for file: ExportedFile, in project: AudiobookProject) -> Int {
        guard let chapterID = file.chapterID,
              let chapter = project.chapters.first(where: { $0.id == chapterID }) else {
            return .max
        }
        return chapter.ordinal
    }
}
