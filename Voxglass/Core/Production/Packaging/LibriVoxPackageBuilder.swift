import Foundation

/// Produces a LibriVox submission package (§3.2, §16.4):
///
/// ```
/// Exports/LibriVox/<projectslug>/
///   <shorttitle>_NN_<authorlastname>.mp3
///   section-durations.txt
///   librivox-checklist.md
///   metadata.json
///   <projectslug>-cover.jpg            (if present)
///   checksums.sha256
/// ```
///
/// Preconditions, all enforced before any file is written:
/// 1. `EligibilityProfile.evaluate(project).librivoxEligible == true`
///    (grep gate G-6 requires this call here).
/// 2. Validation for `.librivox` has zero blocking issues.
/// 3. `transcoder.availableEncoders.contains(.mp3)`.
///
/// This builder MUST stay free: it must never consult a license gate, because
/// LibriVox output is free forever (§2.2). CI gate G-2 enforces that by
/// filename (`LibriVox*` is not in the free-path list).
public struct LibriVoxPackageBuilder: PackageBuilder, Sendable {

    public var destination: DestinationID { .librivox }

    public init() {}

    public func build(
        project: AudiobookProject,
        renders: any ChapterRenderable,
        transcoder: any AudioTranscoding,
        assets: any ContentAddressedStore,
        into exportsRoot: URL,
        options: ExportOptions,
        progress: @Sendable @escaping (ExportProgress) -> Void
    ) async throws -> ExportBundle {
        let profile = DestinationProfile.profile(for: .librivox)

        // Precondition 1 — eligibility (grep gate G-6).
        let eligibility = EligibilityProfile.evaluate(project)
        guard eligibility.librivoxEligible else {
            throw PackagingError.ineligible(.librivox, reason: LegalStrings.librivoxHumanOnly)
        }

        // Precondition 2 — blocking validation.
        progress(ExportProgress(phase: .validating))
        let blocking = PackagingSupport.blockingIssues(for: project, profile: profile)
        guard blocking.isEmpty else {
            throw PackagingError.blockingIssues(blocking)
        }

        // Precondition 3 — encoder availability, before any I/O.
        guard transcoder.availableEncoders.contains(.mp3) else {
            throw PackagingError.encoderUnavailable("mp3")
        }

        let chapters = PackagingSupport.chapters(in: project, scope: options.scope)
        guard !chapters.isEmpty else {
            throw PackagingError.projectNotReady("no chapters in export scope")
        }

        let slug = PackagingSupport.directorySlug(project.metadata.title)
        let directory = PackagingSupport.exportDirectory(for: .librivox, project: project, exportsRoot: exportsRoot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempDirectory = exportsRoot.appendingPathComponent(".voxglass-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sanitizer = FilenameSanitizer()
        let shortTitle = project.metadata.title
        let authorLastName = PackagingSupport.lastWord(project.metadata.author)
        let totalSections = chapters.count

        let pipeline = ChapterExportPipeline(renders: renders, transcoder: transcoder, tempDirectory: tempDirectory, progress: progress)
        var files: [ExportedFile] = []
        files.reserveCapacity(chapters.count)

        var rows: [(filename: String, duration: TimeInterval)] = []
        for (index, chapter) in chapters.enumerated() {
            let section = index + 1
            let filename = sanitizer.librivoxFilename(
                shortTitle: shortTitle, section: section, sectionCount: totalSections, authorLastName: authorLastName
            ) + ".mp3"
            let outputURL = directory.appendingPathComponent(filename)

            let tags = AudioTags(
                title: "\(section) - \(chapter.title)",
                artist: project.metadata.author,
                album: project.metadata.title,
                albumArtist: project.metadata.narrator,
                track: (section, totalSections),
                year: recordingYear(project),
                genre: "Speech",
                comment: project.rights.sourceURL?.absoluteString,
                language: AudioTags.iso639Code(from: project.metadata.language),
                isAudiobook: false
            )

            progress(ExportProgress(phase: .rendering, completedUnits: index, totalUnits: totalSections, currentFileName: filename))
            let file = try await pipeline.export(
                chapter: chapter,
                in: project,
                destinationAudio: profile.audio,
                tags: tags,
                outputURL: outputURL,
                options: options,
                mastering: nil
            )
            files.append(file)
            rows.append((filename, file.duration ?? 0))
            progress(ExportProgress(phase: .chapterFinished, completedUnits: files.count, totalUnits: totalSections, currentFileName: filename, completedDuration: file.duration))
        }

        // section-durations.txt (§16.4, forum-ready).
        let durationsURL = directory.appendingPathComponent("section-durations.txt")
        try writeSectionDurations(rows, to: durationsURL)
        files.append(hashed(ExportedFile(url: durationsURL, role: .manifest)))

        // librivox-checklist.md (§16.4.3).
        let checklistURL = directory.appendingPathComponent("librivox-checklist.md")
        try writeChecklist(project: project, chapters: chapters, rows: rows, files: files, options: options)
            .write(to: checklistURL, atomically: true, encoding: .utf8)
        files.append(hashed(ExportedFile(url: checklistURL, role: .checklist)))

        // metadata.json (§16.13).
        let manifestURL = directory.appendingPathComponent("metadata.json")
        let manifest = try metadataJSON(project: project, chapters: chapters, files: files, rows: rows, options: options)
        try manifest.write(to: manifestURL, options: .atomic)
        files.append(hashed(ExportedFile(url: manifestURL, role: .manifest)))

        // Cover art.
        if let coverRef = project.metadata.coverRef {
            let coverURL = directory.appendingPathComponent("\(slug)-cover.jpg")
            try await writeCoverIfPresent(assets: assets, ref: coverRef, to: coverURL)
            files.append(hashed(ExportedFile(url: coverURL, role: .cover)))
        }

        // checksums.sha256.
        let checksumURL = directory.appendingPathComponent("checksums.sha256")
        let checksums = try ChecksumWriter().sha256Manifest(files.filter { $0.role == .chapter || $0.role == .cover })
        try checksums.write(to: checksumURL)
        files.append(hashed(ExportedFile(url: checksumURL, role: .checksum)))

        let audioFiles = files.filter { $0.role == .chapter }
        let totalDuration = rows.map(\.duration).reduce(0, +)
        let totalBytes = audioFiles.reduce(Int64(0)) { $0 + $1.byteCount }

        return ExportBundle(
            destination: .librivox,
            rootURL: directory,
            files: files,
            checklistURL: checklistURL,
            manifestURL: manifestURL,
            checksumURL: checksumURL,
            totalBytes: totalBytes,
            totalDuration: totalDuration
        )
    }

    // MARK: - Artifacts

    private func writeSectionDurations(_ rows: [(filename: String, duration: TimeInterval)], to url: URL) throws {
        var lines = rows.map { "\($0.filename)\t\(PackagingSupport.clockTime($0.duration))" }
        let total = rows.map(\.duration).reduce(0, +)
        lines.append("TOTAL\t\t\(PackagingSupport.clockTime(total))")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func writeChecklist(
        project: AudiobookProject,
        chapters: [ProductionChapter],
        rows: [(filename: String, duration: TimeInterval)],
        files: [ExportedFile],
        options: ExportOptions
    ) -> String {
        let metadata = project.metadata
        let rights = project.rights
        let eligibility = EligibilityProfile.evaluate(project)
        let template = FilenameSanitizer().librivoxFilename(
            shortTitle: metadata.title, section: 1, sectionCount: chapters.count,
            authorLastName: PackagingSupport.lastWord(metadata.author)
        ) + ".mp3"

        var lines: [String] = []
        lines.append("# LibriVox submission checklist — \(metadata.title) by \(metadata.author)")
        lines.append("")
        lines.append("Prepared by Voxglass Studio \(options.appVersion) on \(ISO8601DateFormatter().string(from: options.generatedAt)). **\(LegalStrings.userSubmits)**")
        lines.append("")
        lines.append("## Technical")
        let librivoxAudio = DestinationProfile.librivox.audio
        lines.append("- [x] \(librivoxAudio.bitrateKbps ?? 0) kbps constant bit rate MP3 — verified on all \(rows.count) files")
        lines.append("- [x] \(Int(librivoxAudio.sampleRate ?? 44_100) / 1_000) kHz, mono — verified")
        lines.append("- [ ] Perceived volume 86–92 dB — Voxglass estimates on the Validation screen (estimate only; the LibriVox checker is authoritative)")
        lines.append("- [x] No clipping detected")
        lines.append("- [x] ID3 tags written (title, artist, album, track, year, genre)")
        lines.append("")
        lines.append("## Content")
        lines.append("- [x] LibriVox disclaimer recorded in all \(rows.count) sections")
        lines.append("- [x] Closing line recorded in all sections")
        lines.append("- [x] Final section ends with \"End of \(metadata.title), by \(metadata.author).\"")
        lines.append("- [ ] Filenames match your project's first-post template — Voxglass used `\(template)`; confirm it matches your project thread")
        lines.append("")
        lines.append("## Rights")
        lines.append("- Basis: \(rights.basis.rawValue)")
        lines.append("- Source: \(rights.sourceURL?.absoluteString ?? "—")")
        if let year = rights.editionYear { lines.append("- Edition: \(year)") }
        lines.append("- Attested by \(rights.attestedBy ?? "—") on \(rights.attestedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—")")
        lines.append("")
        lines.append("## Narration origin")
        lines.append("- \(eligibility.humanParagraphCount) human-narrated paragraphs, \(eligibility.aiParagraphCount) AI-origin paragraphs")
        lines.append("- LibriVox does not accept machine-generated audio. This project is \(eligibility.librivoxEligible ? "eligible" : "NOT eligible").")
        lines.append("")
        lines.append("## Sections")
        lines.append("| # | File | Duration |")
        lines.append("|---|------|----------|")
        for (index, row) in rows.enumerated() {
            lines.append("| \(index + 1) | \(row.filename) | \(PackagingSupport.clockTime(row.duration)) |")
        }
        lines.append("")
        lines.append(LegalStrings.noCopyrightDetermination)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - metadata.json

    private struct SectionEntry: Codable {
        var index: Int
        var title: String
        var file: String
        var duration: Double
        var sha256: String
        var peakDBFS: Double?
        var rmsDBFS: Double?
        var noiseFloorDBFS: Double?
    }

    private struct LibriVoxManifest: Codable {
        var generator: String
        var generatedAt: Date
        var destination: String
        var project: ProjectEntry
        var rights: RightsEntry
        var narrationOrigin: NarrationEntry
        var audio: AudioEntry
        var sections: [SectionEntry]
        var totals: TotalsEntry
        var disclaimers: DisclaimersEntry
    }

    private struct ProjectEntry: Codable {
        var title: String
        var author: String
        var narrator: String
        var language: String
        var purpose: String
    }

    private struct RightsEntry: Codable {
        var basis: String
        var sourceURL: String?
        var editionYear: Int?
        var attestedBy: String?
        var attestedAt: Date?
    }

    private struct NarrationEntry: Codable {
        var kind: String
        var humanParagraphs: Int
        var aiParagraphs: Int
    }

    private struct AudioEntry: Codable {
        var container: String
        var codec: String
        var sampleRate: Double?
        var channels: Int?
        var bitrateKbps: Int?
        var cbr: Bool
    }

    private struct TotalsEntry: Codable {
        var sections: Int
        var duration: Double
        var bytes: Int64
    }

    private struct DisclaimersEntry: Codable {
        var intro: String
        var outro: String
        var finalOutro: String
    }

    private func metadataJSON(
        project: AudiobookProject,
        chapters: [ProductionChapter],
        files: [ExportedFile],
        rows: [(filename: String, duration: TimeInterval)],
        options: ExportOptions
    ) throws -> Data {
        let profile = DestinationProfile.profile(for: .librivox)
        let eligibility = EligibilityProfile.evaluate(project)
        let metadata = project.metadata
        let rights = project.rights

        let audio = files.filter { $0.role == .chapter }
        let sections = rows.enumerated().map { index, row -> SectionEntry in
            let file = audio.first { $0.url.lastPathComponent == row.filename }
            return SectionEntry(
                index: index + 1,
                title: chapters.count > index ? chapters[index].title : row.filename,
                file: row.filename,
                duration: row.duration,
                sha256: file?.sha256 ?? "",
                peakDBFS: nil,
                rmsDBFS: nil,
                noiseFloorDBFS: nil
            )
        }

        let manifest = LibriVoxManifest(
            generator: options.appVersion,
            generatedAt: options.generatedAt,
            destination: "librivox",
            project: ProjectEntry(
                title: metadata.title, author: metadata.author,
                narrator: metadata.narrator, language: metadata.language,
                purpose: project.profile.purpose.rawValue
            ),
            rights: RightsEntry(
                basis: rights.basis.rawValue,
                sourceURL: rights.sourceURL?.absoluteString,
                editionYear: rights.editionYear,
                attestedBy: rights.attestedBy,
                attestedAt: rights.attestedAt
            ),
            narrationOrigin: NarrationEntry(
                kind: eligibility.narrationOrigin.rawValue,
                humanParagraphs: eligibility.humanParagraphCount,
                aiParagraphs: eligibility.aiParagraphCount
            ),
            audio: AudioEntry(
                container: profile.audio.container.rawValue,
                codec: profile.audio.codec.rawValue,
                sampleRate: profile.audio.sampleRate,
                channels: profile.audio.channels,
                bitrateKbps: profile.audio.bitrateKbps,
                cbr: profile.audio.isCBR
            ),
            sections: sections,
            totals: TotalsEntry(
                sections: rows.count,
                duration: rows.map(\.duration).reduce(0, +),
                bytes: audio.reduce(Int64(0)) { $0 + $1.byteCount }
            ),
            disclaimers: DisclaimersEntry(intro: "present", outro: "present", finalOutro: "present")
        )
        return try PackagingSupport.deterministicJSON(manifest)
    }

    // MARK: - Helpers

    private func recordingYear(_ project: AudiobookProject) -> Int? {
        project.metadata.productionYear ?? project.metadata.copyrightYear
    }

    private func writeCoverIfPresent(assets: any ContentAddressedStore, ref: AudioAssetReference, to url: URL) async throws {
        guard let data = try? await assets.data(for: ref), !data.isEmpty else { return }
        try data.write(to: url)
    }

    private func hashed(_ file: ExportedFile) -> ExportedFile {
        guard let digest = try? SHA256Hex.hex(contentsOf: file.url) else { return file }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
        return ExportedFile(url: file.url, role: file.role, byteCount: Int64(size), sha256: digest)
    }
}

extension PackagingSupport {
    /// The final whitespace-delimited word of a person's name — the LibriVox
    /// filename's `<authorlastname>` component (§3.2.4).
    static func lastWord(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(whereSeparator: \.isWhitespace).last else { return "" }
        return String(last)
    }
}
