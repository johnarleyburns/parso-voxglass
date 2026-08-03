import Foundation

/// Produces an Internet Archive package (§3.3, §16.9):
///
/// ```
/// Exports/InternetArchive/<identifier>/
///   <identifier>_NN_<chapterslug>.flac   (lossless masters)
///   <identifier>_NN_<chapterslug>.mp3    (optional profile-bitrate derivative set)
///   <identifier>.jpg                     (cover)
///   <identifier>_meta.json
///   <identifier>_meta.xml
///   <identifier>_files.sha256
///   submission-checklist.md
/// ```
///
/// Preconditions (before any file is written): validation for `.internetArchive`
/// clean; a valid `archiveIdentifier` present; FLAC available (else WAV masters
/// are produced with a warning, §16.9). Voxglass NEVER uploads — the checklist
/// includes a ready-to-paste `ia upload` command for the human to run (§3.3.4).
public struct InternetArchivePackageBuilder: PackageBuilder, Sendable {

    public var destination: DestinationID { .internetArchive }

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
        let profile = DestinationProfile.profile(for: .internetArchive)

        // Identifier preconditions fail fast, before any validation or I/O.
        guard let identifier = project.metadata.archiveIdentifier, !identifier.isEmpty else {
            throw PackagingError.projectNotReady("Internet Archive export requires an archive.org identifier (Metadata & Rights).")
        }
        guard IdentifierSuggester().isValid(identifier) else {
            throw PackagingError.projectNotReady("The archive.org identifier '\(identifier)' is invalid (ASCII alphanumerics plus - _ ., 5–80 characters).")
        }

        progress(ExportProgress(phase: .validating))
        let blocking = PackagingSupport.blockingIssues(
            for: project, profile: profile,
            context: ValidationContext(aiDisclosurePresent: true)
        )
        guard blocking.isEmpty else {
            throw PackagingError.blockingIssues(blocking)
        }

        // Lossless masters: FLAC preferred, WAV fallback (§16.9).
        let masterCodec: Codec = transcoder.availableEncoders.contains(.flac) ? .flac : .pcm
        var warnings: [String] = []
        if masterCodec == .pcm {
            warnings.append("FLAC encoder unavailable; producing WAV masters instead. Enable FLAC for lossless-in-lossless delivery.")
        }

        let chapters = PackagingSupport.chapters(in: project, scope: options.scope)
        guard !chapters.isEmpty else {
            throw PackagingError.projectNotReady("no chapters in export scope")
        }

        let directory = exportsRoot.appendingPathComponent("InternetArchive", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempDirectory = exportsRoot.appendingPathComponent(".voxglass-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sanitizer = FilenameSanitizer()
        let masterSpec = masterCodec == .flac ? profile.audio : AudioSpec(container: .wav, codec: .pcm, bitDepth: 24)
        let derivativeSpec = profile.secondaryAudio

        let pipeline = ChapterExportPipeline(renders: renders, transcoder: transcoder, tempDirectory: tempDirectory, progress: progress)
        var files: [ExportedFile] = []
        var rows: [(filename: String, duration: TimeInterval)] = []

        for (index, chapter) in chapters.enumerated() {
            let section = index + 1
            let slug = sanitizer.sanitize(chapter.title, rule: .archiveIdentifierPrefixed)
            let masterName = sanitizer.archiveFilename(
                identifier: identifier, section: section, sectionCount: chapters.count,
                chapterTitle: slug.isEmpty ? chapter.title : slug,
                ext: masterCodec == .flac ? "flac" : "wav"
            )
            let masterURL = directory.appendingPathComponent(masterName)
            let tags = AudioTags(
                title: chapter.title,
                artist: project.metadata.author,
                album: project.metadata.title,
                track: (section, chapters.count),
                year: recordingYear(project),
                genre: "Audiobook",
                narrator: project.metadata.narrator,
                language: AudioTags.iso639Code(from: project.metadata.language),
                description: project.metadata.description,
                isAudiobook: true
            )
            progress(ExportProgress(phase: .rendering, completedUnits: index, totalUnits: chapters.count, currentFileName: masterName))
            let masterFile = try await pipeline.export(
                chapter: chapter, in: project,
                destinationAudio: masterSpec, tags: tags,
                outputURL: masterURL, options: options, mastering: nil
            )
            files.append(masterFile)
            rows.append((masterName, masterFile.duration ?? 0))

            if options.includeMP3Derivatives, let derivativeSpec {
                let derivativeName = sanitizer.archiveFilename(
                    identifier: identifier, section: section, sectionCount: chapters.count,
                    chapterTitle: slug.isEmpty ? chapter.title : slug,
                    ext: "mp3"
                )
                let derivativeURL = directory.appendingPathComponent(derivativeName)
                progress(ExportProgress(phase: .transcoding, currentFileName: derivativeName))
                let derivative = try await transcoder.transcode(
                    input: masterURL, to: derivativeSpec, tags: tags,
                    output: derivativeURL, progress: { _ in }
                )
                var marked = derivative
                marked.role = .secondaryAudio
                files.append(marked)
            }
        }

        // Cover art.
        if let coverRef = project.metadata.coverRef {
            let coverURL = directory.appendingPathComponent("\(identifier).jpg")
            if let data = try? await assets.data(for: coverRef), !data.isEmpty {
                try data.write(to: coverURL)
                files.append(hashed(ExportedFile(url: coverURL, role: .cover)))
            }
        }

        // <identifier>_meta.json (§3.3.2, §16.9).
        let manifestURL = directory.appendingPathComponent("\(identifier)_meta.json")
        let manifest = try metaJSON(project: project, identifier: identifier, rows: rows, files: files, options: options, warnings: warnings)
        try manifest.write(to: manifestURL, options: .atomic)
        files.append(hashed(ExportedFile(url: manifestURL, role: .manifest)))

        // <identifier>_meta.xml (archive-style convenience copy, §3.3.3).
        let metaXMLURL = directory.appendingPathComponent("\(identifier)_meta.xml")
        try writeMetaXML(project: project, identifier: identifier, to: metaXMLURL)
        files.append(hashed(ExportedFile(url: metaXMLURL, role: .manifest)))

        // submission-checklist.md with the ready-to-paste ia command.
        let checklistURL = directory.appendingPathComponent("submission-checklist.md")
        try writeChecklist(project: project, identifier: identifier, rows: rows, files: files, options: options)
            .write(to: checklistURL, atomically: true, encoding: .utf8)
        files.append(hashed(ExportedFile(url: checklistURL, role: .checklist)))

        // <identifier>_files.sha256.
        let checksumURL = directory.appendingPathComponent("\(identifier)_files.sha256")
        let checksums = try ChecksumWriter().sha256Manifest(files.filter { $0.role == .chapter || $0.role == .secondaryAudio || $0.role == .cover })
        try checksums.write(to: checksumURL)
        files.append(hashed(ExportedFile(url: checksumURL, role: .checksum)))

        let audioFiles = files.filter { $0.role == .chapter || $0.role == .secondaryAudio }
        let totalDuration = rows.map(\.duration).reduce(0, +)
        let totalBytes = audioFiles.reduce(Int64(0)) { $0 + $1.byteCount }

        return ExportBundle(
            destination: .internetArchive,
            rootURL: directory,
            files: files,
            checklistURL: checklistURL,
            manifestURL: manifestURL,
            checksumURL: checksumURL,
            totalBytes: totalBytes,
            totalDuration: totalDuration,
            warnings: warnings
        )
    }

    // MARK: - meta.json

    private struct IAManifest: Codable {
        var identifier: String
        var mediatype: String
        var collection: String
        var title: String
        var creator: [String]
        var performer: String
        var date: String
        var language: String
        var description: String
        var subject: [String]
        var licenseurl: String?
        var rights: String
        var source: String?
        var runtime: String
        var notes: String
        var scanner: String
    }

    private func metaJSON(
        project: AudiobookProject,
        identifier: String,
        rows: [(filename: String, duration: TimeInterval)],
        files: [ExportedFile],
        options: ExportOptions,
        warnings: [String]
    ) throws -> Data {
        let metadata = project.metadata
        let rights = project.rights
        let eligibility = EligibilityProfile.evaluate(project)
        let hasAI = eligibility.narrationOrigin == .containsImportedAI

        let collection = options.useTestCollection ? "test_collection" : "opensource_audio"
        let description = metadata.description.isEmpty
            ? "Audiobook narrated by \(metadata.narrator)."
            : "\(metadata.description)\n\nSource edition: \(rights.editionYear.map(String.init) ?? "unknown year")."
        let rightsLine = "\(rights.basis.rawValue). Recording released to the public domain by the narrator."
        let notes = hasAI ? LegalStrings.aiDisclosure : ""
        let totalDuration = rows.map(\.duration).reduce(0, +)

        let manifest = IAManifest(
            identifier: identifier,
            mediatype: "audio",
            collection: collection,
            title: metadata.title,
            creator: [metadata.author],
            performer: metadata.narrator,
            date: String(metadata.productionYear ?? metadata.copyrightYear ?? Calendar.current.component(.year, from: options.generatedAt)),
            language: AudioTags.iso639Code(from: metadata.language) ?? "eng",
            description: description,
            subject: metadata.subjects.isEmpty ? ["audiobook"] : metadata.subjects,
            licenseurl: rights.licenseURL?.absoluteString,
            rights: rightsLine,
            source: rights.sourceURL?.absoluteString,
            runtime: PackagingSupport.clockTime(totalDuration),
            notes: notes,
            scanner: options.appVersion
        )
        return try PackagingSupport.deterministicJSON(manifest)
    }

    // MARK: - meta.xml

    private func writeMetaXML(project: AudiobookProject, identifier: String, to url: URL) throws {
        let metadata = project.metadata
        let rights = project.rights
        let eligibility = EligibilityProfile.evaluate(project)
        let hasAI = eligibility.narrationOrigin == .containsImportedAI
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<metadata>\n"
        xml += "  <identifier>\(escape(identifier))</identifier>\n"
        xml += "  <title>\(escape(metadata.title))</title>\n"
        xml += "  <creator>\(escape(metadata.author))</creator>\n"
        xml += "  <subject>\(escape(metadata.subjects.joined(separator: ", ")))</subject>\n"
        xml += "  <language>\(escape(AudioTags.iso639Code(from: metadata.language) ?? "eng"))</language>\n"
        xml += "  <source>\(escape(rights.sourceURL?.absoluteString ?? ""))</source>\n"
        if let url = rights.licenseURL { xml += "  <licenseurl>\(escape(url.absoluteString))</licenseurl>\n" }
        if hasAI { xml += "  <notes>\(escape(LegalStrings.aiDisclosure))</notes>\n" }
        xml += "</metadata>\n"
        try Data(xml.utf8).write(to: url)
    }

    private func escape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Checklist

    private func writeChecklist(
        project: AudiobookProject,
        identifier: String,
        rows: [(filename: String, duration: TimeInterval)],
        files: [ExportedFile],
        options: ExportOptions
    ) -> String {
        let metadata = project.metadata
        let collection = options.useTestCollection ? "test_collection" : "opensource_audio"
        let masters = files.filter { $0.role == .chapter }
        let derivatives = files.filter { $0.role == .secondaryAudio }
        let subjectArgs = (metadata.subjects.isEmpty ? ["audiobook"] : metadata.subjects)
            .map { "--metadata='subject:\($0)'" }
            .joined(separator: " \\\n  ")

        var command = "ia upload \(identifier) \\\n"
        command += "  --metadata='mediatype:audio' \\\n"
        command += "  --metadata='collection:\(collection)' \\\n"
        command += "  --metadata='title:\(metadata.title)' \\\n"
        command += "  --metadata='creator:\(metadata.author)' \\\n"
        command += "  --metadata='date:\(metadata.productionYear ?? metadata.copyrightYear ?? 0)' \\\n"
        command += "  --metadata='language:\(AudioTags.iso639Code(from: metadata.language) ?? "eng")' \\\n"
        command += "  --metadata='licenseurl:\(project.rights.licenseURL?.absoluteString ?? "")' \\\n"
        command += "  \(subjectArgs) \\\n"
        command += "  \(masters.map(\.url.lastPathComponent).joined(separator: " "))"
        if !derivatives.isEmpty {
            command += " \(derivatives.map(\.url.lastPathComponent).joined(separator: " "))"
        }
        if let cover = files.first(where: { $0.role == .cover }) {
            command += " \(cover.url.lastPathComponent)"
        }

        let hasAI = EligibilityProfile.evaluate(project).narrationOrigin == .containsImportedAI
        var lines: [String] = []
        lines.append("# Internet Archive submission checklist — \(metadata.title)")
        lines.append("")
        lines.append("Prepared by Voxglass Studio \(options.appVersion) on \(ISO8601DateFormatter().string(from: options.generatedAt)).")
        lines.append("")
        lines.append("## What Voxglass produced")
        lines.append("- \(masters.count) lossless chapter master\(masters.count == 1 ? "" : "s") (\(masters.first?.url.pathExtension ?? ""))")
        let iaAudio = DestinationProfile.internetArchive.secondaryAudio
        if !derivatives.isEmpty { lines.append("- \(derivatives.count) MP3 derivative\(derivatives.count == 1 ? "" : "s") (\(iaAudio?.bitrateKbps ?? 0) kbps CBR, \(Int((iaAudio?.sampleRate ?? 44_100) / 1_000)) kHz, mono)") }
        if let cover = files.first(where: { $0.role == .cover }) { lines.append("- Cover art: \(cover.url.lastPathComponent)") }
        lines.append("- Metadata manifest: \(identifier)_meta.json / \(identifier)_meta.xml")
        lines.append("- Checksums: \(identifier)_files.sha256")
        lines.append("")
        if hasAI {
            lines.append("## Narration origin")
            lines.append("- \(LegalStrings.aiDisclosure) (added to the manifest `notes` field automatically).")
            lines.append("")
        }
        lines.append("## Upload (your action, not Voxglass's)")
        lines.append("Review this command before running it. Uploading is your action, not Voxglass's.")
        lines.append("")
        lines.append("```bash")
        lines.append(command)
        lines.append("```")
        lines.append("")
        if options.useTestCollection {
            lines.append("> Collection `test_collection` is a dry-run target: items are removed automatically after about 30 days. Recommended for your first upload (§3.3.1).")
            lines.append("")
        } else {
            lines.append("> Collection `opensource_audio` is the default community-audio collection for audiobooks (§3.3.1).")
            lines.append("")
        }
        lines.append("## Identifier")
        lines.append("Identifiers are permanent and must be unique on archive.org. Confirm availability before uploading.")
        lines.append("")
        lines.append(LegalStrings.noCopyrightDetermination)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func recordingYear(_ project: AudiobookProject) -> Int? {
        project.metadata.productionYear ?? project.metadata.copyrightYear
    }

    private func hashed(_ file: ExportedFile) -> ExportedFile {
        guard let digest = try? SHA256Hex.hex(contentsOf: file.url) else { return file }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
        return ExportedFile(url: file.url, role: file.role, byteCount: Int64(size), sha256: digest)
    }
}
