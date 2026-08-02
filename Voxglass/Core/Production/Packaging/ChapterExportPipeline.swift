import Foundation

/// Shared render → (master) → transcode → tag → hash pipeline for the package
/// builders (§16.1). Keeps the three builders free of the encoder mechanics and
/// guarantees identical progress reporting and hashing everywhere.
struct ChapterExportPipeline: Sendable {

    let renders: any ChapterRenderable
    let transcoder: any AudioTranscoding
    let tempDirectory: URL
    let progress: @Sendable (ExportProgress) -> Void

    init(
        renders: any ChapterRenderable,
        transcoder: any AudioTranscoding,
        tempDirectory: URL,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) {
        self.renders = renders
        self.transcoder = transcoder
        self.tempDirectory = tempDirectory
        self.progress = progress
    }

    /// Render `chapter` losslessly, optionally master it (retail), transcode to
    /// `destinationAudio` with `tags`, and write to `outputURL`.
    func export(
        chapter: ProductionChapter,
        in project: AudiobookProject,
        destinationAudio: AudioSpec,
        tags: AudioTags,
        outputURL: URL,
        options: ExportOptions,
        mastering: MasteringTarget?
    ) async throws -> ExportedFile {
        let plan = PackagingSupport.renderPlan(for: chapter, in: project)
        let renderURL = tempDirectory.appendingPathComponent("render-\(chapter.id.uuidString).caf")
        progress(ExportProgress(phase: .rendering, currentFileName: chapter.title))

        let rendering = try await renders.render(plan, to: renderURL, progress: { _ in })

        var sourceURL = renderURL
        if let mastering {
            let masteredURL = tempDirectory.appendingPathComponent("mastered-\(chapter.id.uuidString).caf")
            progress(ExportProgress(phase: .mastering, currentFileName: chapter.title))
            _ = try await transcoder.master(input: renderURL, target: mastering, output: masteredURL)
            sourceURL = masteredURL
        }

        progress(ExportProgress(phase: .transcoding, currentFileName: outputURL.lastPathComponent))
        let file = try await transcoder.transcode(
            input: sourceURL,
            to: destinationAudio,
            tags: tags,
            output: outputURL,
            progress: { _ in }
        )

        // Prefer the rendered duration (what the chapter list will show); the
        // transcoder's estimate differs by encoder padding only.
        var result = file
        result.chapterID = chapter.id
        result.duration = rendering.duration
        return result
    }
}
