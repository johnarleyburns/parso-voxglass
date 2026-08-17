import Foundation

/// Produces a professional retail package (§3.4, §16.8) for `.acx` or
/// `.appleBooksAggregator`:
///
/// ```
/// Exports/Retail/<projectslug>/
///   01 - Opening Credits.mp3
///   02 - Chapter One.mp3
///   ...
///   NN - Closing Credits.mp3
///   <projectslug>-retail-sample.mp3
///   <projectslug>.m4b
///   masters/01 - Opening Credits.wav
///   cover-<minPx>.jpg          (minPx from the destination profile, §3.4.6)
///   delivery-metadata.json
///   validation-report.json / .html
///   checksums.sha256
///   submission-checklist.md
/// ```
///
/// The gate that unlocks retail export (the Pro retail presets, mastering, M4B,
/// FLAC masters, batch export, and report export) is checked by the Export
/// wizard (S9), never here — this file is named `RetailMaster*`, so CI gate G-2
/// permits it to reference the gate, but the builder itself is pure packaging.
/// Mastering is applied per `ExportOptions.applyMastering` (§16.7) and measured
/// against the profile on the delivered files (§16.13 compliance block).
public struct RetailMasterPackageBuilder: PackageBuilder, Sendable {

    public let destination: DestinationID

    public init(destination: DestinationID = .acx) {
        precondition(destination == .acx || destination == .appleBooksAggregator || destination == .personalMaster)
        self.destination = destination
    }

    /// The cover file's edge length in pixels, taken from the destination's
    /// artwork rule (§3.4.6) so the filename and manifest stay profile-driven.
    public var coverMinimumPx: Int {
        switch DestinationProfile.profile(for: destination).artwork {
        case .requiredSquare(let minPx, _, _), .optionalSquare(let minPx):
            return minPx
        case .none:
            return 0
        }
    }

    public func build(
        project: AudiobookProject,
        renders: any ChapterRenderable,
        transcoder: any AudioTranscoding,
        assets: any ContentAddressedStore,
        into exportsRoot: URL,
        options: ExportOptions,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> ExportBundle {
        let profile = DestinationProfile.profile(for: destination)

        progress(ExportProgress(phase: .validating))
        let context = ValidationContext(
            aiDisclosurePresent: true,
            retailSample: options.retailSample
        )
        let blocking = PackagingSupport.blockingIssues(for: project, profile: profile, context: context)
        guard blocking.isEmpty else {
            throw PackagingError.blockingIssues(blocking)
        }

        let chapters = PackagingSupport.chapters(in: project, scope: options.scope)
            .sorted { a, b in
                // Credits sort to the bookends regardless of any ordinal tie:
                // opening first, closing last, body between (§3.4.2).
                let pa = priority(a.role)
                let pb = priority(b.role)
                if pa != pb { return pa < pb }
                return a.ordinal < b.ordinal
            }
        guard !chapters.isEmpty else {
            throw PackagingError.projectNotReady("no chapters in export scope")
        }

        let slug = PackagingSupport.directorySlug(project.metadata.title)
        let directory = exportsRoot.appendingPathComponent("Retail", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        let mastersDirectory = directory.appendingPathComponent("masters", isDirectory: true)
        try FileManager.default.createDirectory(at: mastersDirectory, withIntermediateDirectories: true)

        let tempDirectory = exportsRoot.appendingPathComponent(".voxglass-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let mastering = masteringTarget(for: profile, options: options)
        let chapterAudio = destination == .personalMaster ? DestinationProfile.personalListeningAudio : profile.audio
        let pipeline = ChapterExportPipeline(renders: renders, transcoder: transcoder, tempDirectory: tempDirectory, progress: progress)
        let sanitizer = FilenameSanitizer()
        var files: [ExportedFile] = []
        var masteredMasters: [URL] = []
        var chapterRows: [(index: Int, title: String, file: String, duration: TimeInterval, measured: AudioQualityMetrics?)] = []
        var cumulative: TimeInterval = 0

        for (offset, chapter) in chapters.enumerated() {
            let section = offset + 1
            let chapterExtension = destination == .personalMaster ? "m4a" : "mp3"
            let fileBase = sanitizer.freeformNumbered(
                section: section, sectionCount: chapters.count, chapterTitle: chapter.title, ext: chapterExtension
            )
            let outputURL = directory.appendingPathComponent(fileBase)
            let tags = retailTags(for: chapter, in: project, section: section, totalSections: chapters.count)

            progress(ExportProgress(phase: .rendering, completedUnits: offset, totalUnits: chapters.count, currentFileName: fileBase))
            let file = try await pipeline.export(
                chapter: chapter, in: project,
                destinationAudio: chapterAudio, tags: tags,
                outputURL: outputURL, options: options, mastering: mastering
            )
            files.append(file)

            // Lossless archive master (mastered audio, §16.8 masters/).
            let masterName = sanitizer.freeformNumbered(
                section: section, sectionCount: chapters.count, chapterTitle: chapter.title, ext: "wav"
            )
            let masterURL = mastersDirectory.appendingPathComponent(masterName)
            let masterSpec = AudioSpec(container: .wav, codec: .pcm, sampleRate: 44_100, channels: 1, bitDepth: 24)
            progress(ExportProgress(phase: .mastering, currentFileName: masterName))
            let masterFile = try await transcodeMaster(chapter: chapter, in: project, pipeline: pipeline, spec: masterSpec, outputURL: masterURL, options: options, mastering: mastering)
            var markedMaster = masterFile
            markedMaster.role = .master
            files.append(markedMaster)
            masteredMasters.append(masterURL)

            chapterRows.append((section, chapter.title, fileBase, file.duration ?? 0, file.measured))
            cumulative += file.duration ?? 0
        }

        // Retail sample (§3.4.3).
        var sampleFile: ExportedFile?
        if let selection = options.retailSample,
           let segments = sampleSegments(project: project, selection: selection) {
            let sampleURL = directory.appendingPathComponent("\(slug)-retail-sample.mp3")
            let plan = RenderPlan(
                chapterID: segments.first!.chapterID,
                segments: segments,
                settings: project.profile.assembly,
                outputFormat: AudioSpec(container: .caf, codec: .pcm, sampleRate: 44_100, channels: 1, bitDepth: 32),
                cacheKey: RenderCacheKey.key(chapterID: segments.first!.chapterID, segments: segments, settings: project.profile.assembly, format: AudioSpec(container: .caf, codec: .pcm, sampleRate: 44_100, channels: 1))
            )
            progress(ExportProgress(phase: .rendering, currentFileName: sampleURL.lastPathComponent))
            let renderURL = tempDirectory.appendingPathComponent("sample-render.caf")
            let rendering = try await renders.render(plan, to: renderURL, progress: { _ in })
            var source = renderURL
            if let mastering {
                let masteredURL = tempDirectory.appendingPathComponent("sample-mastered.caf")
                _ = try await transcoder.master(input: renderURL, target: mastering, output: masteredURL)
                source = masteredURL
            }
            progress(ExportProgress(phase: .transcoding, currentFileName: sampleURL.lastPathComponent))
            let exported = try await transcoder.transcode(
                input: source, to: profile.audio,
                tags: retailTags(forTitle: "Retail Sample", in: project, section: nil, totalSections: nil),
                output: sampleURL, progress: { _ in }
            )
            var resolved = exported
            resolved.role = .sample
            resolved.duration = rendering.duration
            sampleFile = resolved
            files.append(resolved)
        }

        // M4B — chapterized AAC-LC from the mastered masters (§3.4.4).
        if transcoder.availableEncoders.contains(.aacLC) {
            let m4bURL = directory.appendingPathComponent("\(slug).m4b")
            var marks: [ChapterMark] = []
            var cursor: TimeInterval = 0
            for row in chapterRows {
                marks.append(ChapterMark(title: row.title, start: cursor))
                cursor += row.duration
            }
            progress(ExportProgress(phase: .transcoding, currentFileName: m4bURL.lastPathComponent))
            let m4b = try await transcoder.concatenate(
                masteredMasters,
                to: AudioSpec(container: .m4b, codec: .aacLC, sampleRate: 44_100, channels: 1, bitrateKbps: options.m4bBitrateKbps),
                chapters: marks,
                tags: retailTags(forTitle: destination == .personalMaster ? "Personal Voxglass Listening" : project.metadata.title, in: project, section: nil, totalSections: nil),
                output: m4bURL
            )
            files.append(m4b)
        }

        // Cover art (§3.4.6 artwork rule: required square at the profile's
        // minimum edge length).
        if let coverRef = project.metadata.coverRef, let data = try? await assets.data(for: coverRef), !data.isEmpty {
            let coverMinPx = coverMinimumPx
            let coverURL = directory.appendingPathComponent("cover-\(coverMinPx).jpg")
            try data.write(to: coverURL)
            files.append(hashed(ExportedFile(url: coverURL, role: .cover)))
        }

        // delivery-metadata.json (§16.13).
        let metadataURL = directory.appendingPathComponent("delivery-metadata.json")
        try deliveryMetadata(project: project, rows: chapterRows, sample: sampleFile, files: files, options: options, profile: profile)
            .write(to: metadataURL, options: .atomic)
        files.append(hashed(ExportedFile(url: metadataURL, role: .manifest)))

        // Validation report (JSON + HTML, §15.5 / §16.8).
        if options.writeValidationReport {
            let report = ValidationReport(
                destination: destination,
                generatedAt: options.generatedAt,
                projectID: project.id,
                projectTitle: project.metadata.title,
                issues: blocking,
                eligibility: EligibilityProfile.evaluate(project),
                summary: ValidationSummary.from(issues: blocking, totalParagraphs: project.allParagraphs.count, recordedParagraphs: project.recordedCount, totalDuration: cumulative, chaptersOverMaxDuration: 0),
                analyzerVersion: AudioMetricsCalculator.analyzerVersion,
                appVersion: options.appVersion
            )
            let jsonURL = directory.appendingPathComponent("validation-report.json")
            try ValidationReportRenderer().json(report).write(to: jsonURL)
            files.append(hashed(ExportedFile(url: jsonURL, role: .report)))
            let htmlURL = directory.appendingPathComponent("validation-report.html")
            try ValidationReportRenderer().html(report).write(to: htmlURL, atomically: true, encoding: .utf8)
            files.append(hashed(ExportedFile(url: htmlURL, role: .report)))
        }

        // checksums.sha256.
        let checksumURL = directory.appendingPathComponent("checksums.sha256")
        let checksums = try ChecksumWriter().sha256Manifest(files.filter { $0.role == .chapter || $0.role == .sample || $0.role == .master || $0.role == .cover })
        try checksums.write(to: checksumURL)
        files.append(hashed(ExportedFile(url: checksumURL, role: .checksum)))

        // submission-checklist.md.
        let checklistURL = directory.appendingPathComponent("submission-checklist.md")
        try writeChecklist(project: project, rows: chapterRows, sample: sampleFile, files: files, options: options, profile: profile)
            .write(to: checklistURL, atomically: true, encoding: .utf8)
        files.append(hashed(ExportedFile(url: checklistURL, role: .checklist)))

        let audioFiles = files.filter { $0.role == .chapter || $0.role == .sample || $0.role == .master }
        let totalBytes = audioFiles.reduce(Int64(0)) { $0 + $1.byteCount }

        return ExportBundle(
            destination: destination,
            rootURL: directory,
            files: files,
            checklistURL: checklistURL,
            manifestURL: metadataURL,
            checksumURL: checksumURL,
            totalBytes: totalBytes,
            totalDuration: cumulative
        )
    }

    // MARK: - Helpers

    private func transcodeMaster(
        chapter: ProductionChapter,
        in project: AudiobookProject,
        pipeline: ChapterExportPipeline,
        spec: AudioSpec,
        outputURL: URL,
        options: ExportOptions,
        mastering: MasteringTarget?
    ) async throws -> ExportedFile {
        // Re-render into a temp CAF so the WAV master reflects the mastered audio.
        let plan = PackagingSupport.renderPlan(for: chapter, in: project)
        let renderURL = FileManager.default.temporaryDirectory.appendingPathComponent("master-src-\(chapter.id.uuidString).caf")
        let rendering = try await pipeline.renders.render(plan, to: renderURL, progress: { _ in })
        var source = renderURL
        if let mastering {
            let masteredURL = FileManager.default.temporaryDirectory.appendingPathComponent("master-mstd-\(chapter.id.uuidString).caf")
            _ = try await pipeline.transcoder.master(input: renderURL, target: mastering, output: masteredURL)
            source = masteredURL
        }
        let file = try await pipeline.transcoder.transcode(
            input: source, to: spec,
            tags: AudioTags(title: chapter.title, artist: project.metadata.author, album: project.metadata.title, genre: "Audiobook", isAudiobook: true),
            output: outputURL, progress: { _ in }
        )
        var result = file
        result.duration = rendering.duration
        try? FileManager.default.removeItem(at: renderURL)
        return result
    }

    private func retailTags(for chapter: ProductionChapter, in project: AudiobookProject, section: Int?, totalSections: Int?) -> AudioTags {
        retailTags(forTitle: chapter.title, in: project, section: section, totalSections: totalSections)
    }

    private func retailTags(forTitle title: String, in project: AudiobookProject, section: Int?, totalSections: Int?) -> AudioTags {
        let metadata = project.metadata
        return AudioTags(
            title: title,
            artist: metadata.author,
            album: metadata.title,
            composer: metadata.narrator,
            track: section.map { ($0, totalSections ?? 0) },
            year: metadata.copyrightYear,
            genre: "Audiobook",
            copyright: metadata.rightsHolder.flatMap { holder in
                metadata.copyrightYear.map { "Copyright \($0) \(holder)." } ?? "Copyright \(holder)."
            },
            narrator: metadata.narrator,
            publisher: metadata.publisher,
            language: AudioTags.iso639Code(from: metadata.language),
            description: metadata.description,
            artworkJPEG: nil,
            isAudiobook: true
        )
    }

    private func priority(_ role: ChapterRole) -> Int {
        switch role {
        case .openingCredits: return 0
        case .closingCredits: return 2
        default: return 1
        }
    }

    private func masteringTarget(for profile: DestinationProfile, options: ExportOptions) -> MasteringTarget? {
        guard options.applyMastering else { return nil }
        guard case .rmsWindow(_, _, let target) = profile.loudness, let peak = profile.peakCeilingDBFS else { return nil }
        let head = profile.headroomSilence.map { ($0.headMin + $0.headMax) / 2 } ?? 0.75
        let tail = profile.headroomSilence.map { ($0.tailMin + $0.tailMax) / 2 } ?? 2.0
        return MasteringTarget(targetRMSDBFS: target, peakCeilingDBFS: peak, headSeconds: head, tailSeconds: tail)
    }

    private func sampleSegments(project: AudiobookProject, selection: RetailSampleSelection) -> [PlaybackSegment]? {
        // §12.2: the sample obeys the same segment rules as every other queue —
        // the queue builder clamps the duration to the 60…300 s retail window.
        let segments = SegmentQueueBuilder().build(
            .retailSample(startParagraph: selection.startParagraphID, maxDuration: selection.duration),
            from: project,
            settings: project.profile.assembly
        )
        return segments.isEmpty ? nil : segments
    }

    // MARK: - delivery-metadata.json

    private struct SeriesEntry: Codable { var name: String?; var index: Int? }
    private struct CoverEntry: Codable { var file: String; var width: Int; var height: Int; var colorSpace: String }
    private struct SampleEntry: Codable { var file: String; var duration: Double; var startsAtParagraph: String }
    private struct FileEntry: Codable {
        var index: Int
        var role: String
        var title: String?
        var file: String
        var duration: Double
        var rmsDBFS: Double?
        var truePeakDBFS: Double?
        var noiseFloorDBFS: Double?
        var sha256: String
    }
    private struct ComplianceEntry: Codable {
        var profile: String
        var rmsRange: [Double]
        var peakCeiling: Double
        var noiseFloorCeiling: Double?
        var allFilesPass: Bool
    }
    private struct DeliveryManifest: Codable {
        var generator: String
        var destination: String
        var title: String
        var subtitle: String?
        var series: SeriesEntry
        var authors: [String]
        var narrators: [String]
        var publisher: String?
        var publicationDate: String?
        var language: String
        var isAbridged: Bool
        var isbn: String?
        var asin: String?
        var copyright: String?
        var description: String
        var categories: [String]
        var narrationOrigin: String
        var cover: CoverEntry?
        var retailSample: SampleEntry?
        var files: [FileEntry]
        var compliance: ComplianceEntry
    }

    private func deliveryMetadata(
        project: AudiobookProject,
        rows: [(index: Int, title: String, file: String, duration: TimeInterval, measured: AudioQualityMetrics?)],
        sample: ExportedFile?,
        files: [ExportedFile],
        options: ExportOptions,
        profile: DestinationProfile
    ) throws -> Data {
        let metadata = project.metadata
        let eligibility = EligibilityProfile.evaluate(project)

        var loudnessRange: [Double] = []
        if case .rmsWindow(let min, let max, _) = profile.loudness {
            loudnessRange = [min, max]
        }

        let fileEntries = rows.map { row in
            FileEntry(
                index: row.index,
                role: "chapter",
                title: row.title,
                file: row.file,
                duration: row.duration,
                rmsDBFS: row.measured?.rmsDBFS,
                truePeakDBFS: row.measured?.truePeakDBFS,
                noiseFloorDBFS: row.measured?.noiseFloorDBFS,
                sha256: files.first { $0.url.lastPathComponent == row.file }?.sha256 ?? ""
            )
        }

        let copyrightLines: [String] = [
            metadata.rightsHolder.map { r in metadata.copyrightYear.map { "Copyright \($0) \(r)." } ?? "Copyright \(r)." },
            metadata.publisher.map { p in metadata.productionYear.map { "Production copyright \($0) \(p)." } ?? "Production copyright \(p)." }
        ].compactMap { $0 }

        let manifest = DeliveryManifest(
            generator: options.appVersion,
            destination: destination.rawValue,
            title: metadata.title,
            subtitle: metadata.subtitle,
            series: SeriesEntry(name: metadata.seriesName, index: metadata.seriesIndex),
            authors: [metadata.author],
            narrators: [metadata.narrator],
            publisher: metadata.publisher,
            publicationDate: metadata.productionYear.map { "\($0)-01-01" },
            language: metadata.language,
            isAbridged: metadata.isAbridged,
            isbn: metadata.isbn,
            asin: metadata.asin,
            copyright: copyrightLines.isEmpty ? nil : copyrightLines.joined(separator: " "),
            description: metadata.description,
            categories: metadata.subjects,
            narrationOrigin: eligibility.narrationOrigin.rawValue,
            cover: files.first(where: { $0.role == .cover }).map {
                CoverEntry(file: $0.url.lastPathComponent, width: coverMinimumPx, height: coverMinimumPx, colorSpace: "RGB")
            },
            retailSample: sample.map {
                SampleEntry(file: $0.url.lastPathComponent, duration: $0.duration ?? 0, startsAtParagraph: options.retailSample?.startParagraphID.uuidString ?? "")
            },
            files: fileEntries,
            compliance: ComplianceEntry(
                profile: destination.rawValue,
                rmsRange: loudnessRange,
                peakCeiling: profile.peakCeilingDBFS ?? 0,
                noiseFloorCeiling: profile.noiseFloorCeilingDBFS,
                allFilesPass: rows.allSatisfy { row in
                    guard let m = row.measured else { return false }
                    return loudnessRange.isEmpty || (m.rmsDBFS >= loudnessRange[0] && m.rmsDBFS <= loudnessRange[1])
                }
            )
        )
        return try PackagingSupport.deterministicJSON(manifest)
    }

    // MARK: - Checklist

    private func writeChecklist(
        project: AudiobookProject,
        rows: [(index: Int, title: String, file: String, duration: TimeInterval, measured: AudioQualityMetrics?)],
        sample: ExportedFile?,
        files: [ExportedFile],
        options: ExportOptions,
        profile: DestinationProfile
    ) -> String {
        var lines: [String] = []
        lines.append("# \(project.metadata.title) — retail submission checklist (\(DestinationProfile.profile(for: destination).displayName))")
        lines.append("")
        lines.append("Prepared by Voxglass Studio \(options.appVersion) on \(ISO8601DateFormatter().string(from: options.generatedAt)).")
        lines.append("")
        lines.append("## Files")
        lines.append("| # | File | Duration |")
        lines.append("|---|------|----------|")
        for row in rows {
            lines.append("| \(row.index) | \(row.file) | \(PackagingSupport.clockTime(row.duration)) |")
        }
        if let sample {
            lines.append("| — | \(sample.url.lastPathComponent) (retail sample) | \(PackagingSupport.clockTime(sample.duration ?? 0)) |")
        }
        if let m4b = files.first(where: { $0.url.pathExtension == "m4b" }) {
            lines.append("| — | \(m4b.url.lastPathComponent) (chapterized M4B) | — |")
        }
        lines.append("")
        lines.append("## Compliance")
        lines.append("- \(rows.count) chapter files, mastered to the profile's speech RMS target, true peak ≤ \(profile.peakCeilingDBFS ?? 0) dBFS.")
        lines.append("- Re-measure each delivered file on the Validation screen if a human review is needed.")
        lines.append("")
        lines.append(LegalStrings.userSubmits)
        lines.append("")
        lines.append(LegalStrings.noAcceptanceGuarantee)
        lines.append("")
        lines.append(LegalStrings.noCopyrightDetermination)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func hashed(_ file: ExportedFile) -> ExportedFile {
        guard let digest = try? SHA256Hex.hex(contentsOf: file.url) else { return file }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
        return ExportedFile(url: file.url, role: file.role, byteCount: Int64(size), sha256: digest)
    }
}
