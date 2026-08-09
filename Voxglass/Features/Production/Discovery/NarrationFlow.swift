import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import VoxglassCore
import VoxglassEncoders

// MARK: - Flow presentation model

/// The selected `Take` of a paragraph, resolved through `selectedTakeID`.
extension Paragraph {
    var selectedTake: Take? {
        guard let id = selectedTakeID else { return nil }
        return takes.first { $0.id == id }
    }
}

/// The state vocabulary the narration flow works in. Derived from a Core
/// `Paragraph`: a recorded-but-unreviewed take, an approved take, a flagged
/// paragraph, or nothing recorded yet.
enum FlowParagraphState: Equatable {
    case notRecorded
    case recorded
    case approved
    case flagged
}

/// The flow's role vocabulary. Both LibriVox opening paragraphs (the disclaimer
/// and the title intro) surface as `.intro`; the closing one as `.outro`.
enum FlowParagraphRole: Equatable {
    case intro
    case body
    case outro

    var label: String {
        switch self {
        case .intro: return "Intro"
        case .outro: return "Outro"
        case .body: return "Paragraph"
        }
    }
}

/// The selected take as the flow presents it: duration plus the metrics that
/// the record screen's status line and the validate screen's clipping check
/// read.
struct FlowTake: Equatable {
    var duration: TimeInterval
    var peakDBFS: Double?
    var clipped: Bool
}

/// A take recovered from an interruption, awaiting the user's keep/discard
/// decision (mockup 06c). Recovered takes are inserted as ordinary takes,
/// marked `Interrupted`, and never selected for the user.
struct FlowRecoveredTake: Identifiable, Equatable {
    let id: UUID
    var reason: CaptureInterruptionReason
    var duration: TimeInterval
    var paragraphID: UUID?
    var fileURL: URL

    init(
        id: UUID = UUID(), // presentation-only identity; not persisted
        reason: CaptureInterruptionReason,
        duration: TimeInterval,
        paragraphID: UUID?,
        fileURL: URL
    ) {
        self.id = id
        self.reason = reason
        self.duration = duration
        self.paragraphID = paragraphID
        self.fileURL = fileURL
    }
}

/// The paragraph as the narration flow sees it — a Core `Paragraph` plus the
/// flow's derived state, its latest review note, and the selected take's
/// presentation. The flow screens read this; the model translates to/from the
/// `AudiobookProject` model underneath.
struct FlowParagraph: Identifiable, Equatable {
    let id: UUID
    var text: String
    var role: FlowParagraphRole
    var state: FlowParagraphState
    var note: String?
    var take: FlowTake?
    /// True when the selected take was recorded against different text than the
    /// paragraph now holds (spec §9.5 step 4). The script editor's "Changed"
    /// filter and chips read this.
    var isDrifted: Bool
}

/// A picked audio file waiting for its import decision (mockup 07). Holds the
/// decoded waveform dimensions so the storage-impact card can be truthful
/// before anything is written.
struct FlowImportedAudio: Equatable, Identifiable {
    let id: UUID
    var sourceURL: URL
    var originalSize: Int64
    var fileName: String
    var format: AudioFormatDescription?
    var duration: TimeInterval
    var decodedSampleRate: Double
    var decodedSampleCount: Int

    init(
        id: UUID = UUID(), // presentation-only identity; not persisted
        sourceURL: URL,
        originalSize: Int64,
        fileName: String,
        format: AudioFormatDescription?,
        duration: TimeInterval,
        decodedSampleRate: Double,
        decodedSampleCount: Int
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.originalSize = originalSize
        self.fileName = fileName
        self.format = format
        self.duration = duration
        self.decodedSampleRate = decodedSampleRate
        self.decodedSampleCount = decodedSampleCount
    }
}

/// The mandatory origin declaration for imported audio (§10). Compliance
/// metadata, not a UI nicety: it must survive SQLite, CloudKit, the manifest,
/// and the validation report. Non-human or unknown origins block LibriVox
/// export once such a take is selected.
enum FlowImportOrigin: String, CaseIterable, Identifiable {
    case selfRecorded
    case humanExternal
    case aiImported
    case unknown

    var id: String { rawValue }

    var isHumanNarration: Bool {
        self == .selfRecorded || self == .humanExternal
    }

    func audioOrigin(fileName: String) -> AudioOrigin {
        switch self {
        case .selfRecorded, .humanExternal:
            return .importedHuman(sourceFilename: fileName)
        case .aiImported:
            return .aiImported(providerLabel: fileName)
        case .unknown:
            return .unknownImport(sourceFilename: fileName)
        }
    }
}

/// Free space on the volume that holds the app's support directory — the
/// number the assembly preflight and the import screen show before work starts.
enum FreeSpaceProvider {
    static var availableBytes: Int64? {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else { return nil }
        return values.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - Flow model

enum NarrationStep: Hashable {
    case importWork
    case reviewSource
    case record(paragraphID: UUID)
    case reviewList
    case assemble
    case metadata
    case validateExport
    case submit
}

/// The eight-step short-work production flow (NARRATION_NEEDS_SPEC §11.4,
/// p01–p08). Single-work and short-only on iPhone. A project may be left and
/// resumed at any step. Projects are `AudiobookProject`s in the SQLite
/// production store (spec §4.3); the flow is a storage client, not a second
/// project model.
@MainActor
@Observable
@MainActor
final class NarrationFlowModel {
    enum ImportSource {
        case need(NarrationNeed)
        case paste
        case files
        case gutenberg
    }

    var project: AudiobookProject?
    var draftTitle = ""
    var draftAuthor = ""
    var draftText = ""
    var sourceURL: String?
    var importError: String?
    var isImporting = false

    var currentParagraphID: UUID?
    let capture: any AudioCapturing
    var isRecording = false
    var micPermissionDenied = false
    var level: Float = 0
    var currentTake: FlowTake?
    var playbackPlayer: AVAudioPlayer?
    private var levelTask: Task<Void, Never>?

    /// The route class of the current recording, snapshotted at record start
    /// (spec §7.1). Persisted on the take so `routeNotRetailReady` is computed
    /// from history.
    var routeClass: CaptureRouteClass?
    /// The cause of the most recent in-flight interruption; shown as the
    /// recovery banner on the record screen (mockup 06c).
    var interruptionBanner: CaptureInterruptionReason?
    /// Takes recovered at launch or in-flight that await keep/discard.
    var pendingRecoveries: [FlowRecoveredTake] = []
    /// The destination URL of the in-flight take (also the autosave path).
    private var recordingDestinationURL: URL?

    /// The phone production relay the record screen registers its recording-remote
    /// session with (spec §14.3). Set by the flow root from the discovery
    /// environment so the watch can start/stop/accept/retake/flag this session.
    var phoneProduction: PhoneProductionEnvironment?

    /// The active recording-remote coordinator while the record screen is up.
    private var recordingRemoteCoordinator: RecordingRemoteCoordinator?
    private var recordingRemoteStatusTask: Task<Void, Never>?
    /// Latest telemetry fed by the capture's level stream, relayed to the watch.
    private var remoteElapsedSeconds: TimeInterval = 0
    private var remoteLevelDBFS: Float = -60

    var assembly = AssemblySettings()
    var narrator = ""
    var language = "English"
    var descriptionText = ""
    var subjectsText = ""
    var sourceURLText = ""
    var exportBundle: NarrationExportBundle?

    /// P7: the live validation report for the selected export destination
    /// (§12). Driven by the real rule engine with the export preflight context,
    /// so a free user sees the exact issues the export pipeline will enforce.
    var validationDestination: DestinationID = .librivox
    var validationIssues: [ValidationIssue] = []
    var preflight: ExportPreflightResult?
    var isValidating = false
    var validationError: String?

    /// P7: the resumable export run state (§13.3).
    var isExporting = false
    var exportError: String?
    var exportProgress: ExportProgress?
    var exportRunRecord: ExportRunRecord?
    private var exportTask: Task<Void, Never>?

    let repository: NarrationProjectRepository
    let fetcher: any HTTPFetching

    /// P9 storage hardening: evicts remote-verified originals after a take is
    /// saved so the working cache never silently exceeds its cap (§6.5, M-5).
    private let storageCoordinator: ProductionStorageCoordinator

    /// The license seam the export destination picker and the export runner
    /// consult (spec §2.2: LicenseGate appears only in the destination picker,
    /// the export runner, and Settings). Recording, review, validation, and
    /// storage never touch it.
    let licenseProvider: any LicenseProvider

    /// The current entitlement, kept fresh from `LicenseProvider.updates` so the
    /// destination picker can flip between free and Pro without re-querying.
    var proEntitlement: EntitlementState = .free
    private var proObservationTask: Task<Void, Never>?

    var isProUnlocked: Bool {
        if case .pro = proEntitlement { return true }
        return false
    }

    var licenseGate: LicenseGate { LicenseGate(provider: licenseProvider) }

    /// Latest review-note text per paragraph, so a flag note survives relaunch
    /// and shows on the review list (stored as `ReviewNote`s in the project DB).
    private var paragraphNotes: [UUID: String] = [:]

    init(
        repository: NarrationProjectRepository = NarrationProjectRepository(),
        fetcher: any HTTPFetching = URLSessionFetcher(),
        existing: AudiobookProject? = nil,
        capture: any AudioCapturing = AudioSessionCapture(),
        licenseProvider: any LicenseProvider = NarrationProStore.shared.provider
    ) {
        self.repository = repository
        self.fetcher = fetcher
        self.capture = capture
        self.licenseProvider = licenseProvider
        self.project = existing
        self.storageCoordinator = ProductionStorageCoordinator(repository: repository)
        if let existing {
            draftTitle = existing.metadata.title
            draftAuthor = existing.metadata.author
            setSource(existing.rights.sourceURL?.absoluteString)
        }
        // The capture forwards in-flight interruptions (call, route change,
        // USB unplug, headphones, background, disk pressure) to the flow,
        // which finalizes and recovers the take (spec §7.4).
        capture.onInterruption = { [weak self] reason in
            Task { @MainActor in
                await self?.handleInterruption(reason)
            }
        }
        // Keep the Pro entitlement fresh from the license seam so the export
        // destination picker reflects purchases, restores, and revocations
        // (§13.5). A revocation reverts to free; no project is touched.
        proObservationTask = Task { [weak self] in
            guard let self else { return }
            self.proEntitlement = await self.licenseProvider.entitlement
            for await state in self.licenseProvider.updates {
                self.proEntitlement = state
            }
        }
    }

    deinit {
        proObservationTask?.cancel()
    }

    // MARK: - Presentation

    var paragraphs: [FlowParagraph] {
        guard let project else { return [] }
        return project.allParagraphs.map { Self.flowParagraph($0, notes: paragraphNotes) }
    }

    var readyToAssemble: Bool {
        guard let project, project.totalCount > 0 else { return false }
        let flagged = project.allParagraphs.count { $0.reviewState == .flagged }
        return flagged == 0 && project.recordedCount == project.totalCount
    }

    var totalDuration: TimeInterval {
        guard let project else { return 0 }
        return project.allParagraphs.reduce(0) { $0 + ($1.selectedTake?.duration ?? 0) }
    }

    /// §15.5 "Record next": the first paragraph in document order with no
    /// selected take, or — if everything is recorded — the first `needsPickup`.
    var recordNextParagraphID: UUID? {
        guard let project else { return nil }
        if let id = project.allParagraphs.first(where: { $0.selectedTakeID == nil })?.id {
            return id
        }
        return project.allParagraphs.first { $0.reviewState == .needsPickup }?.id
    }

    var rightsAttested: Bool {
        project?.rights.isAttested ?? false
    }

    private static func flowParagraph(_ paragraph: Paragraph, notes: [UUID: String]) -> FlowParagraph {
        FlowParagraph(
            id: paragraph.id,
            text: paragraph.text,
            role: flowRole(paragraph.role),
            state: flowState(paragraph),
            note: notes[paragraph.id],
            take: paragraph.selectedTake.map { FlowTake(duration: $0.duration, peakDBFS: $0.metrics?.peakDBFS, clipped: ($0.metrics?.clipCount ?? 0) > 0) },
            isDrifted: hasDrift(paragraph)
        )
    }

    private static func hasDrift(_ paragraph: Paragraph) -> Bool {
        guard let selected = paragraph.selectedTakeID,
              let take = paragraph.takes.first(where: { $0.id == selected }) else { return false }
        return paragraph.textHash != take.textHashAtRecording
    }

    private static func flowRole(_ role: ParagraphRole) -> FlowParagraphRole {
        switch role {
        case .libriVoxIntro: return .intro
        case .libriVoxOutro: return .outro
        default: return .body
        }
    }

    private static func flowState(_ paragraph: Paragraph) -> FlowParagraphState {
        switch paragraph.reviewState {
        case .approved: return .approved
        case .flagged: return .flagged
        default:
            return paragraph.selectedTakeID != nil ? .recorded : .notRecorded
        }
    }

    // MARK: - Import

    /// The Need ID of the work being imported; stamped onto the project's sync
    /// state so a later start of the same need resumes this project.
    var pendingNeedID: String?

    /// Keeps the project's source URL and the Metadata "Source URL" field in
    /// sync so the export records where the text came from (Gutenberg, a need's
    /// source page, a forum, etc.) instead of an empty field.
    func setSource(_ url: String?) {
        sourceURL = url
        sourceURLText = url ?? ""
    }

    func importNeed(_ need: NarrationNeed) {
        pendingNeedID = need.id
        draftTitle = need.work.title
        draftAuthor = need.work.author
        draftText = need.work.text ?? ""
        setSource(need.work.sourcePageURL?.absoluteString)
    }

    func importPastedText(title: String, author: String, text: String) {
        pendingNeedID = nil
        draftTitle = title
        draftAuthor = author
        draftText = text
        setSource(nil)
    }

    func fetchGutenberg(identifier: String) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            importError = "Enter a gutenberg.org link or ebook number."
            return
        }
        let ebookID = id.contains("gutenberg.org") ? (URL(string: id)?.lastPathComponent ?? id) : id
        guard let url = URL(string: "https://www.gutenberg.org/cache/epub/\(ebookID)/pg\(ebookID).txt") else {
            importError = "Couldn't build a Gutenberg URL."
            return
        }
        do {
            let result = try await fetcher.get(url, timeout: 15, userAgent: "Voxglass/1.1 (narration-needs; contact: hello@parso.guru)")
            guard result.statusCode == 200 else {
                importError = "Gutenberg returned HTTP \(result.statusCode)."
                return
            }
            let text = String(decoding: result.data, as: UTF8.self)
            draftText = stripProjectGutenberg(text)
            setSource("https://www.gutenberg.org/ebooks/\(ebookID)")
            // Best-effort title/author from the header block.
            if let titleLine = firstHeaderLine(text, matching: "Title:") { draftTitle = titleLine }
            if let authorLine = firstHeaderLine(text, matching: "Author:") { draftAuthor = authorLine }
        } catch {
            importError = "Couldn't reach Project Gutenberg. Paste the text instead."
        }
    }

    // MARK: - Segmentation

    /// Builds the project: auto-inserted LibriVox intro/outro paragraphs plus
    /// the segmented body (p02), persisted as an `AudiobookProject` in the
    /// production store.
    func buildParagraphs() async {
        let body = Self.narrationParagraphs(from: draftText)

        // A work with no text on this device would produce a project whose
        // only paragraphs are the LibriVox header/footer — nothing to read.
        // Refuse to create it instead of sending the user into an empty
        // recording flow (field fix: "narration asks to record NO CONTENT").
        guard !body.isEmpty else {
            importError = "This work doesn't have its text on this device yet. Try another short work."
            return
        }

        let now = repository.clock.now
        let title = draftTitle.isEmpty ? "This work" : draftTitle
        let author = draftAuthor.isEmpty ? "Unknown" : draftAuthor
        let reader = narrator.isEmpty ? "your name" : narrator

        var paragraphs: [Paragraph] = []
        var ordinal = 0
        let disclaimer = "This is a LibriVox recording. All LibriVox recordings are in the public domain. For more information, or to volunteer, please visit librivox dot org."
        paragraphs.append(paragraph(disclaimer, role: .libriVoxIntro, ordinal: ordinal, at: now))
        ordinal += 1
        let intro = "\(title), by \(author). Read for LibriVox by \(reader)."
        paragraphs.append(paragraph(intro, role: .libriVoxIntro, ordinal: ordinal, at: now))
        ordinal += 1
        for text in body {
            paragraphs.append(paragraph(text, role: .body, ordinal: ordinal, at: now))
            ordinal += 1
        }
        let outro = "End of \(title). This recording is in the public domain."
        paragraphs.append(paragraph(outro, role: .libriVoxOutro, ordinal: ordinal, at: now))

        let chapter = ProductionChapter(id: repository.ids.next(), ordinal: 0, title: title, role: .body, paragraphs: paragraphs)
        let project = AudiobookProject(
            id: repository.ids.next(),
            metadata: BookMetadata(title: title, author: author, narrator: "", language: "en-US"),
            rights: RightsEvidence(basis: .publicDomainUS, sourceURL: sourceURL.flatMap(URL.init(string:))),
            profile: ProductionProfile(
                purpose: .publicDomainCommunity,
                recording: RecordingDefaults(),
                intendedDestination: .librivox
            ),
            source: nil,
            chapters: [chapter],
            createdAt: now,
            modifiedAt: now
        )
        self.project = project
        if let needID = pendingNeedID {
            try? await repository.setNeedID(needID, for: project.id)
        }
        if !draftText.isEmpty {
            try? await repository.setSourceText(draftText, for: project.id)
        }
    }

    /// Builds a multi-chapter project from an imported source document (file
    /// import path). Chapter structure from the `Segmenter` is preserved so a
    /// long work reaches the dashboard with correct per-chapter counts (P5).
    func buildFromDocument(_ document: ExtractedDocument) async {
        let builder = NarrationProjectBuilder()
        let title = draftTitle.isEmpty ? "This work" : draftTitle
        let author = draftAuthor.isEmpty ? "Unknown" : draftAuthor

        let build = builder.build(
            document: document,
            title: title,
            author: author,
            narrator: narrator,
            sourceURL: URL(string: sourceURL ?? ""),
            ids: repository.ids,
            clock: repository.clock
        )

        guard !build.project.allParagraphs.isEmpty else {
            importError = "This work doesn't have its text on this device yet. Try another work."
            return
        }

        if let needID = pendingNeedID {
            try? await repository.setNeedID(needID, for: build.project.id)
        }
        if !document.plainText.isEmpty {
            try? await repository.setSourceText(document.plainText, for: build.project.id)
        }
        draftText = document.plainText
        draftTitle = title
        draftAuthor = author
        project = build.project
    }

    private func paragraph(_ text: String, role: ParagraphRole, ordinal: Int, at date: Date) -> Paragraph {
        Paragraph(
            id: repository.ids.next(),
            ordinal: ordinal,
            text: text,
            textHash: TextNormalizer.hash(text),
            role: role,
            updatedAt: date
        )
    }

    /// Groups raw text into narration paragraphs. Blank lines are paragraph
    /// breaks; lines within a paragraph are kept on their own lines (poems
    /// read line by line). Blocks that still exceed `maxLength` (no blank
    /// lines anywhere — e.g. poems or pasted prose) are split at sentence
    /// boundaries so a single take stays a comfortable read.
    static func narrationParagraphs(from text: String, maxLength: Int = 1000) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty {
                    blocks.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            blocks.append(current.joined(separator: "\n"))
        }

        var paragraphs: [String] = []
        for block in blocks {
            paragraphs.append(contentsOf: Self.splitParagraph(block, maxLength: maxLength))
        }
        return paragraphs
    }

    /// Splits a block longer than `maxLength` at sentence boundaries.
    private static func splitParagraph(_ block: String, maxLength: Int) -> [String] {
        guard block.count > maxLength else { return [block] }
        var parts: [String] = []
        var rest = block
        while rest.count > maxLength {
            let window = String(rest.prefix(maxLength))
            let cut = Self.sentenceBoundary(in: window) ?? window.count
            let part = window.prefix(cut).trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty { parts.append(part) }
            rest = String(rest.dropFirst(cut)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !rest.isEmpty { parts.append(rest) }
        return parts
    }

    /// Index just past the last sentence-ending punctuation (`.`, `!`, `?`),
    /// or nil when the window has none.
    private static func sentenceBoundary(in text: String) -> Int? {
        var last: Int?
        for (index, char) in text.enumerated() where char == "." || char == "!" || char == "?" {
            last = index + 1
        }
        return last
    }

    // MARK: - Resume / navigation

    /// Finds an already-started project for the same need (by need ID, then
    /// legacy work identity) so re-tapping a need resumes it instead of
    /// creating a duplicate.
    func existingProject(for need: NarrationNeed) async -> AudiobookProject? {
        await repository.existingProject(for: need)
    }

    /// Loads an existing project into the flow (resume path).
    func resume(_ project: AudiobookProject) async {
        self.project = project
        draftTitle = project.metadata.title
        draftAuthor = project.metadata.author
        setSource(project.rights.sourceURL?.absoluteString)
        pendingNeedID = await repository.needID(for: project.id)
        draftText = await repository.sourceText(for: project.id) ?? ""
        narrator = project.metadata.narrator
        language = project.metadata.language.isEmpty ? "English" : project.metadata.language
        descriptionText = project.metadata.description
        subjectsText = project.metadata.subjects.joined(separator: "; ")
        paragraphNotes = await repository.latestNotes(for: project.id)
        currentParagraphID = nil
        importError = nil
        micPermissionDenied = false
        await checkForRecoveredSessions()
    }

    func paragraph(at id: UUID) -> FlowParagraph? {
        paragraphs.first { $0.id == id }
    }

    /// The number of takes recorded or imported for a paragraph, including
    /// archived ones — drives the take-comparison affordance (mockup 08).
    func takeCount(for paragraphID: UUID) -> Int {
        guard let project, let paragraph = project.allParagraphs.first(where: { $0.id == paragraphID }) else { return 0 }
        return paragraph.takes.count
    }

    func nextParagraph(after id: UUID) -> FlowParagraph? {
        guard let project else { return nil }
        guard let index = project.allParagraphs.firstIndex(where: { $0.id == id }) else { return nil }
        let nextIndex = project.allParagraphs.index(after: index)
        guard project.allParagraphs.indices.contains(nextIndex) else { return nil }
        return Self.flowParagraph(project.allParagraphs[nextIndex], notes: paragraphNotes)
    }

    func previousParagraph(before id: UUID) -> FlowParagraph? {
        guard let project, let index = project.allParagraphs.firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        return Self.flowParagraph(project.allParagraphs[index - 1], notes: paragraphNotes)
    }

    func updateParagraph(_ id: UUID, _ transform: (inout Paragraph) -> Void) {
        guard var project else { return }
        guard let chapterIndex = project.chapters.firstIndex(where: { $0.paragraphs.contains { $0.id == id } }),
              let paragraphIndex = project.chapters[chapterIndex].paragraphs.firstIndex(where: { $0.id == id }) else { return }
        transform(&project.chapters[chapterIndex].paragraphs[paragraphIndex])
        project.modifiedAt = repository.clock.now
        self.project = project
    }

    /// Durably saves the current project. Called from async action handlers
    /// where the write must be ordered (take bytes first, then metadata);
    /// the root view also persists through `DiscoveryEnvironment.save` on
    /// change, so a missed call cannot strand a project.
    func persist() async {
        guard let project else { return }
        try? await repository.save(project)
    }

    // MARK: - Script editing (spec §8.4)

    /// The global document position of a paragraph (1-based), as the script
    /// editor numbers its rows ("¶ 1205").
    func globalNumber(of id: UUID) -> Int? {
        project?.allParagraphs.firstIndex(where: { $0.id == id }).map { $0 + 1 }
    }

    /// Splits a paragraph at a character offset. The existing take stays on the
    /// first half; the second half starts unrecorded (mockup 05 banner). Never
    /// deletes a take.
    func splitParagraph(_ id: UUID, atCharacterOffset offset: Int) async {
        guard var project,
              let chapterIndex = project.chapters.firstIndex(where: { $0.paragraphs.contains { $0.id == id } }),
              let paragraphIndex = project.chapters[chapterIndex].paragraphs.firstIndex(where: { $0.id == id }) else { return }
        let paragraph = project.chapters[chapterIndex].paragraphs[paragraphIndex]
        let split = ParagraphSplitter().split(paragraph, atCharacterOffset: offset, ids: repository.ids, clock: repository.clock)
        project.chapters[chapterIndex].paragraphs.remove(at: paragraphIndex)
        project.chapters[chapterIndex].paragraphs.insert(contentsOf: [split.first, split.second], at: paragraphIndex)
        renumberParagraphs(in: &project.chapters[chapterIndex])
        project.modifiedAt = repository.clock.now
        self.project = project
        await persist()
    }

    /// Merges a paragraph into the previous one. The merged paragraph keeps the
    /// first's id and selected take; the second's takes are archived, never
    /// deleted.
    func mergeParagraph(_ id: UUID) async {
        guard var project,
              let chapterIndex = project.chapters.firstIndex(where: { $0.paragraphs.contains { $0.id == id } }),
              let paragraphIndex = project.chapters[chapterIndex].paragraphs.firstIndex(where: { $0.id == id }),
              paragraphIndex > 0 else { return }
        var chapter = project.chapters[chapterIndex]
        let second = chapter.paragraphs.remove(at: paragraphIndex)
        let first = chapter.paragraphs[paragraphIndex - 1]
        let merged = ParagraphSplitter().merge(first, second, clock: repository.clock)
        chapter.paragraphs[paragraphIndex - 1] = merged
        renumberParagraphs(in: &chapter)
        project.chapters[chapterIndex] = chapter
        project.modifiedAt = repository.clock.now
        self.project = project
        await persist()
    }

    /// Applies an edited paragraph text. Editing a paragraph that has a selected
    /// take raises the drift indicator immediately (mockup 05) because the rule
    /// engine compares `textHash` to `take.textHashAtRecording`.
    func editParagraphText(_ id: UUID, to text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateParagraph(id) { paragraph in
            paragraph.text = trimmed
            paragraph.textHash = TextNormalizer.hash(trimmed)
            paragraph.updatedAt = repository.clock.now
        }
        await persist()
    }

    private func renumberParagraphs(in chapter: inout ProductionChapter) {
        for index in chapter.paragraphs.indices {
            chapter.paragraphs[index].ordinal = index
        }
    }

    // MARK: - Recording

    func startRecordingParagraph(_ id: UUID) async {
        guard let project, paragraph(at: id) != nil else { return }
        currentParagraphID = id
        importError = nil
        micPermissionDenied = false
        interruptionBanner = nil
        let directory = repository.autosaveTakesURL(for: project.id)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // §7.3: capture at 48 kHz / 24-bit mono WAV when the hardware supports
        // it; the capture falls back to the actual hardware format otherwise.
        let url = directory.appendingPathComponent("\(repository.ids.next().uuidString).wav")
        recordingDestinationURL = url
        // Autosave session (§7.7): written before the engine starts, deleted on
        // a normal stop, present at launch iff a take needs recovery.
        writeAutosaveSession(for: id, url: url, project: project)
        do {
            try await capture.prepare(device: nil, format: RecordingDefaults())
            try await capture.startRecording(to: url)
            routeClass = CaptureRouteClassifier.classify(capture.currentRouteInfo)
            isRecording = true
            monitorLevels()
        } catch let error as CaptureError where error == .permissionDenied {
            micPermissionDenied = true
            importError = "Microphone access is blocked. Allow the microphone in Settings → Privacy → Microphone, then try again."
            AutosaveSessionFile.delete(at: repository.layout(for: project.id).autosaveSessionURL)
        } catch {
            importError = "Couldn't start recording. \(error.localizedDescription)"
            AutosaveSessionFile.delete(at: repository.layout(for: project.id).autosaveSessionURL)
        }
    }

    func stopRecordingParagraph(_ id: UUID) async {
        guard isRecording else { return }
        do {
            let captured = try await capture.stopRecording()
            isRecording = false
            levelTask?.cancel()
            levelTask = nil
            guard let project else { return }
            let textHash = project.allParagraphs.first { $0.id == id }?.textHash ?? ""
            let chapter = project.chapters.first { $0.paragraphs.contains { $0.id == id } }
            let take = try await repository.ingestCapturedTake(
                fileURL: captured.fileURL,
                paragraphID: id,
                projectID: project.id,
                captured: captured,
                textHash: textHash,
                chapterID: chapter?.id,
                chapterOrdinal: chapter?.ordinal,
                warning: .none,
                routeClass: routeClass
            )
            updateParagraph(id) { paragraph in
                paragraph.takes.append(take)
                paragraph.selectedTakeID = take.id
                paragraph.reviewState = .unreviewed
                // A retake archives by state, never by file removal (§9.4).
                for index in paragraph.takes.indices where paragraph.takes[index].id != take.id {
                    paragraph.takes[index].isArchived = true
                }
                paragraph.updatedAt = repository.clock.now
            }
            currentTake = FlowTake(duration: captured.duration, peakDBFS: captured.peakDBFS, clipped: captured.clippedDuringCapture)
            AutosaveSessionFile.delete(at: repository.layout(for: project.id).autosaveSessionURL)
            await persist()
            // P9 storage hardening (§6.5): the new take is `.localOnly` (never
            // evictable); if the working cache has grown past its cap, oldest
            // remote-verified chapters are offloaded to fit.
            await storageCoordinator.evictIfOverLimit(
                projectID: project.id,
                activeChapterOrdinal: chapter?.ordinal
            )
        } catch {
            isRecording = false
            levelTask?.cancel()
            levelTask = nil
        }
    }

    /// In-flight interruption path (spec §7.4): the capture forwards a cause,
    /// this stops and finalizes the take through `CaptureRecovery`, ingests it
    /// marked `Interrupted`, and shows the recovery banner.
    func handleInterruption(_ reason: CaptureInterruptionReason) async {
        guard isRecording, let project, let id = currentParagraphID else { return }
        isRecording = false
        levelTask?.cancel()
        levelTask = nil
        guard let url = recordingDestinationURL else {
            interruptionBanner = reason
            return
        }
        do {
            let recovered = try await CaptureRecovery.handleInFlightInterruption(
                reason: reason, capture: capture, destinationURL: url
            )
            let textHash = project.allParagraphs.first { $0.id == id }?.textHash ?? ""
            let chapter = project.chapters.first { $0.paragraphs.contains { $0.id == id } }
            let take = try await repository.ingestCapturedTake(
                fileURL: recovered.fileURL,
                paragraphID: id,
                projectID: project.id,
                captured: CapturedTake(
                    fileURL: recovered.fileURL,
                    duration: recovered.duration,
                    format: recovered.format,
                    clippedDuringCapture: recovered.clippedDuringCapture,
                    peakDBFS: recovered.peakDBFS
                ),
                textHash: textHash,
                chapterID: chapter?.id,
                chapterOrdinal: chapter?.ordinal,
                warning: .interrupted,
                routeClass: routeClass
            )
            updateParagraph(id) { paragraph in
                paragraph.takes.append(take)
                // Recovered takes are never selected for the user
                // (mockup 06c: "Nothing is selected for you").
                paragraph.updatedAt = repository.clock.now
            }
            AutosaveSessionFile.delete(at: repository.layout(for: project.id).autosaveSessionURL)
            await persist()
            await storageCoordinator.evictIfOverLimit(
                projectID: project.id,
                activeChapterOrdinal: chapter?.ordinal
            )
        } catch {
            // The take stays on disk and the session stays; it will be offered
            // again at the next launch.
            interruptionBanner = reason
        }
    }

    /// Checks for a take left behind by a force-quit at the last launch and
    /// offers it for keep/discard (spec §7.4 row 7). Idempotent.
    func checkForRecoveredSessions() async {
        guard let project, pendingRecoveries.isEmpty else { return }
        let layout = repository.layout(for: project.id)
        guard let recovered = try? CaptureRecovery.recoverAfterLaunch(sessionURL: layout.autosaveSessionURL) else { return }
        let session = try? AutosaveSessionFile.read(from: layout.autosaveSessionURL)
        pendingRecoveries.append(FlowRecoveredTake(
            reason: recovered.reason,
            duration: recovered.duration,
            paragraphID: session?.paragraphID,
            fileURL: recovered.fileURL
        ))
    }

    /// "Keep as take": ingests a recovered take, marked `Interrupted`, never
    /// selected for the user (mockup 06c).
    func keepRecovered(_ recovery: FlowRecoveredTake) async {
        guard let project else { return }
        guard let paragraphID = recovery.paragraphID,
              let paragraph = project.allParagraphs.first(where: { $0.id == paragraphID }),
              let info = try? WAVFormatReader.read(url: recovery.fileURL) else {
            discardRecovered(recovery)
            return
        }
        do {
            let chapter = project.chapters.first { $0.paragraphs.contains { $0.id == paragraphID } }
            let take = try await repository.ingestCapturedTake(
                fileURL: recovery.fileURL,
                paragraphID: paragraphID,
                projectID: project.id,
                captured: CapturedTake(
                    fileURL: recovery.fileURL,
                    duration: info.duration,
                    format: info.audioFormat,
                    clippedDuringCapture: false,
                    peakDBFS: -60
                ),
                textHash: paragraph.textHash,
                chapterID: chapter?.id,
                chapterOrdinal: chapter?.ordinal,
                warning: .interrupted,
                routeClass: nil
            )
            updateParagraph(paragraphID) { paragraph in
                paragraph.takes.append(take)
                paragraph.updatedAt = repository.clock.now
            }
            AutosaveSessionFile.delete(at: repository.layout(for: project.id).autosaveSessionURL)
            pendingRecoveries.removeAll { $0.id == recovery.id }
            await persist()
        } catch {
            discardRecovered(recovery)
        }
    }

    /// "Discard": removes the recovered file and its autosave session.
    func discardRecovered(_ recovery: FlowRecoveredTake) {
        try? FileManager.default.removeItem(at: recovery.fileURL)
        pendingRecoveries.removeAll { $0.id == recovery.id }
        if let project {
            AutosaveSessionFile.delete(at: repository.layout(for: project.id).autosaveSessionURL)
        }
    }

    /// Dismisses the in-flight interruption banner after it has been read.
    func dismissInterruptionBanner() {
        interruptionBanner = nil
    }

    /// "Resume on iPhone mic": starts a fresh take on the interrupted
    /// paragraph (mockup 06c). The recovered take stays in the paragraph list.
    func resumeRecordingOnCurrentRoute() {
        interruptionBanner = nil
        if let id = currentParagraphID {
            Task { await startRecordingParagraph(id) }
        }
    }

    // MARK: - Recording remote (spec §14.3)

    /// Registers this flow as the phone's active recording-remote session. Called
    /// when the record screen appears: a fresh `sessionID` scopes command
    /// idempotency, and a relay task pushes live status to the watch.
    func beginRecordingRemoteSession() {
        guard let phoneProduction else { return }
        let sessionID = repository.ids.next()
        let coordinator = RecordingRemoteCoordinator(
            sessionID: sessionID,
            state: { [weak self] in self?.capture.state ?? .idle },
            handler: { [weak self] action in
                await self?.handleRemoteAction(action)
            }
        )
        recordingRemoteCoordinator = coordinator
        phoneProduction.recordingRemoteCoordinator = coordinator
        recordingRemoteStatusTask?.cancel()
        recordingRemoteStatusTask = Task { [weak self] in
            await self?.relayRecordingRemoteStatus(sessionID: sessionID)
        }
    }

    /// Unregisters the session when the record screen disappears.
    func endRecordingRemoteSession() {
        recordingRemoteStatusTask?.cancel()
        recordingRemoteStatusTask = nil
        recordingRemoteCoordinator = nil
        phoneProduction?.recordingRemoteCoordinator = nil
    }

    /// Maps a watch command onto the same phone-only actions the record screen
    /// drives. All five are gated by the coordinator to the armed/recording
    /// states, and all run on the main actor, so the watch can never mutate
    /// project state out from under the UI.
    private func handleRemoteAction(_ action: RecordingRemoteAction) async {
        switch action {
        case .record:
            if !isRecording, let id = currentParagraphID {
                await startRecordingParagraph(id)
            }
        case .stop:
            if isRecording, let id = currentParagraphID {
                await stopRecordingParagraph(id)
            }
        case .retake:
            if isRecording, let id = currentParagraphID {
                await stopRecordingParagraph(id)
            }
            if let id = currentParagraphID {
                await startRecordingParagraph(id)
            }
        case .accept:
            if isRecording, let id = currentParagraphID {
                await stopRecordingParagraph(id)
            }
            if let id = currentParagraphID {
                acceptParagraph(id)
                await persist()
                advanceAfterRemoteCompletion(from: id, flag: false)
            }
        case .flag:
            if isRecording, let id = currentParagraphID {
                await stopRecordingParagraph(id)
            }
            if let id = currentParagraphID {
                flagParagraph(id, note: "")
                await persist()
                advanceAfterRemoteCompletion(from: id, flag: true)
            }
        }
    }

    private func advanceAfterRemoteCompletion(from id: UUID, flag: Bool) {
        if let next = nextParagraph(after: id) {
            currentParagraphID = next.id
        } else {
            currentParagraphID = nil
        }
        _ = flag
    }

    /// Pushes a status frame to the watch at a phone-friendly cadence. The watch
    /// shows paragraph, elapsed take time, and input level; no audio crosses the
    /// link (spec §14.3).
    private func relayRecordingRemoteStatus(sessionID: UUID) async {
        while !Task.isCancelled {
            let paragraphNumber: Int
            let chapterTitle: String
            if let project, let id = currentParagraphID {
                paragraphNumber = project.allParagraphs.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
                let chapter = project.chapters.first { $0.paragraphs.contains { $0.id == id } }
                chapterTitle = chapter?.title ?? ""
            } else {
                paragraphNumber = 0
                chapterTitle = ""
            }
            let state = capture.state
            let isRecordingNow = state == .recording
            let status = RecordingRemoteStatus(
                sessionID: sessionID,
                paragraphID: currentParagraphID,
                paragraphNumber: paragraphNumber,
                chapterTitle: chapterTitle,
                elapsedSeconds: isRecordingNow ? remoteElapsedSeconds : 0,
                levelDBFS: isRecordingNow ? remoteLevelDBFS : -60,
                isRecording: isRecordingNow,
                isArmed: isRecordingNow || state == .prepared || state == .monitoring
            )
            await phoneProduction?.pushRecordingRemoteStatus(status)
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    /// The route chip text for the record screen (mockup 06): transport name
    /// plus readiness class.
    var routeChipText: String {        let transport = Self.transportLabel(capture.currentRouteInfo.transports)
        let klass = routeClass ?? CaptureRouteClassifier.classify(capture.currentRouteInfo)
        return "\(transport) · \(CaptureRouteClassifier.label(for: klass).lowercased())"
    }

    private static func transportLabel(_ transports: Set<CapturePortTransport>) -> String {
        if transports.contains(.usb) { return "USB-C interface" }
        if transports.contains(.bluetooth) { return "Bluetooth" }
        if transports.contains(.wiredHeadset) { return "Wired headset" }
        if transports.contains(.builtIn) { return "iPhone mic" }
        if transports.contains(.airPlay) { return "AirPlay" }
        return "Current input"
    }

    private func writeAutosaveSession(for paragraphID: UUID, url: URL, project: AudiobookProject) {
        let layout = repository.layout(for: project.id)
        let chapter = project.chapters.first { $0.paragraphs.contains { $0.id == paragraphID } }
        guard let relativePath = layout.relativePath(of: url) else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
        let session = AutosaveSession(
            takeID: repository.ids.next(),
            paragraphID: paragraphID,
            chapterID: chapter?.id,
            filePath: relativePath,
            format: AutosaveSession.Format(sampleRate: 48_000, channels: 1, bitDepth: 24),
            startedAt: repository.clock.now.timeIntervalSince1970,
            appVersion: version
        )
        try? AutosaveSessionFile.write(session, to: layout.autosaveSessionURL)
    }

    func acceptParagraph(_ id: UUID) {
        updateParagraph(id) { paragraph in
            paragraph.reviewState = .approved
            paragraph.updatedAt = repository.clock.now
        }
        currentTake = nil
    }

    func flagParagraph(_ id: UUID, note: String) {
        updateParagraph(id) { paragraph in
            paragraph.reviewState = .flagged
            paragraph.updatedAt = repository.clock.now
        }
        if !note.isEmpty {
            paragraphNotes[id] = note
            if let project {
                let reviewNote = ReviewNote(paragraphID: id, text: note, device: .iPhone, createdAt: repository.clock.now)
                Task { try? await repository.insertNote(reviewNote, projectID: project.id) }
            }
        }
        currentTake = nil
    }

    /// Records the public-domain attestation and folds the metadata draft
    /// fields into the project (p06).
    func attest() {
        guard var project else { return }
        project.rights.attestedAt = repository.clock.now
        project.rights.attestedBy = narrator.isEmpty ? "narrator" : narrator
        project.metadata.narrator = narrator
        project.metadata.language = language
        project.metadata.description = descriptionText
        project.metadata.subjects = subjectsText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        project.modifiedAt = repository.clock.now
        self.project = project
    }

    // MARK: - Levels

    private func monitorLevels() {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            guard let self else { return }
            for await levels in self.capture.levels {
                self.level = max(levels.peakDBFS, -60)
                // The recording remote relays the same telemetry to the watch
                // (spec §14.3): elapsed take time and input level.
                self.remoteElapsedSeconds = levels.sampleTime
                self.remoteLevelDBFS = levels.peakDBFS
            }
        }
    }

    func playbackURL(for id: UUID) -> URL? {
        guard let project, let paragraph = project.allParagraphs.first(where: { $0.id == id }),
              let take = paragraph.selectedTake else { return nil }
        return repository.takeURL(for: project.id, take: take)
    }

    /// The URL of the most recent non-archived take on a paragraph — used to
    /// "play what was saved" after an interruption, when the recovered take is
    /// deliberately not selected (mockup 06c).
    func latestTakePlaybackURL(for id: UUID) -> URL? {
        guard let project, let paragraph = project.allParagraphs.first(where: { $0.id == id }),
              let take = paragraph.takes.last(where: { !$0.isArchived }) else { return nil }
        return repository.takeURL(for: project.id, take: take)
    }

    func play(_ id: UUID) {
        guard let url = playbackURL(for: id) else { return }
        play(url: url)
    }

    /// Plays the most recent take on a paragraph (the recovered one after an
    /// interruption).
    func playLatestTake(_ id: UUID) {
        guard let url = latestTakePlaybackURL(for: id) else { return }
        play(url: url)
    }

    private func play(url: URL) {
        // The capture session is `.record`; take playback needs `.playback`
        // or the audio is silent. Recording re-enters `.record` on the next
        // startRecordingParagraph call.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        playbackPlayer = try? AVAudioPlayer(contentsOf: url)
        playbackPlayer?.play()
    }

    // MARK: - Take selection (spec §9.5)

    /// URL of any take's audio, not just the selected one — the take
    /// comparison (mockup 08) plays archived takes too.
    func takeURL(_ takeID: UUID, in paragraphID: UUID) -> URL? {
        guard let project,
              let paragraph = project.allParagraphs.first(where: { $0.id == paragraphID }),
              let take = paragraph.takes.first(where: { $0.id == takeID }) else { return nil }
        return repository.takeURL(for: project.id, take: take)
    }

    /// Plays a specific take (mockup 08 "Play").
    func play(_ takeID: UUID, in paragraphID: UUID) {
        guard let url = takeURL(takeID, in: paragraphID) else { return }
        play(url: url)
    }

    /// Selects a take for a paragraph — a project mutation, therefore
    /// phone-only (spec §9.5). The other takes are archived by state, never
    /// deleted (§9.4).
    func selectTake(_ takeID: UUID, for paragraphID: UUID) async {
        guard let project, project.allParagraphs.contains(where: { $0.id == paragraphID }) else { return }
        updateParagraph(paragraphID) { paragraph in
            guard paragraph.takes.contains(where: { $0.id == takeID }) else { return }
            paragraph.selectedTakeID = takeID
            paragraph.reviewState = .approved
            for index in paragraph.takes.indices {
                paragraph.takes[index].isArchived = paragraph.takes[index].id != takeID
            }
            paragraph.updatedAt = repository.clock.now
        }
        await persist()
    }

    /// The A/B comparison for a paragraph's two most recent takes (mockup 08).
    /// Archived takes stay comparable — a retake archives by state, never by
    /// deletion (§9.4) — and the newer take is `takeA`.
    func takeComparison(for paragraphID: UUID) -> TakeComparison? {
        guard let project, let paragraph = project.allParagraphs.first(where: { $0.id == paragraphID }),
              paragraph.takes.count >= 2 else { return nil }
        let ordered = Array(paragraph.takes.suffix(2).reversed())
        return TakeComparison(
            takeA: comparisonSide(ordered[0], in: paragraph),
            takeB: comparisonSide(ordered[1], in: paragraph)
        )
    }

    private func comparisonSide(_ take: Take, in paragraph: Paragraph) -> TakeComparison.Side {
        let number = (paragraph.takes.firstIndex(where: { $0.id == take.id }) ?? 0) + 1
        let m = take.metrics
        return TakeComparison.Side(
            takeID: take.id,
            label: take.label ?? "Take \(number)",
            isSelected: take.id == paragraph.selectedTakeID,
            isArchived: take.isArchived,
            recordedAt: take.recordedAt,
            routeClass: take.routeClass,
            duration: take.duration,
            peakDBFS: m?.peakDBFS,
            rmsDBFS: m?.rmsDBFS,
            noiseFloorDBFS: m?.noiseFloorDBFS,
            replayGainDB: m?.replayGainDB
        )
    }

    // MARK: - Assembly settings (mockup 10)

    /// Applies the assembly spacing/toggle plan to the project profile and
    /// persists it. The plan is non-destructive: gaps, trims, and loudness are
    /// metadata the renderer applies, never edits to the original takes
    /// (spec §11.1).
    func applyAssembly(_ updated: AssemblySettings) async {
        assembly = updated
        guard var project else { return }
        project.profile.assembly = updated
        project.modifiedAt = repository.clock.now
        self.project = project
        await persist()
    }

    // MARK: - Assembly rendering (spec §11.2, M-4)

    /// The render state the assembly screen shows per chapter (mockup 10):
    /// current, stale (spacing/takes changed since the last render), or not
    /// recorded yet.
    enum ChapterRenderState: Equatable {
        case notRecorded
        case current
        case stale
    }

    var isRendering = false
    var renderProgress: ChunkedRenderCoordinator.Progress?
    var renderError: String?
    var renderStatuses: [UUID: ChapterRenderState] = [:]
    private var renderTask: Task<Void, Never>?

    /// The render cache and store for the current project, resolved once per
    /// call. Renders live in `Audio/Render/` and are the first eviction class.
    private func renderComponents(for project: AudiobookProject) -> (renderer: AVChapterRenderer, cache: ProductionRenderCache, assets: FileAssetStore) {
        let layout = repository.layout(for: project.id)
        let fileStore = repository.fileStore(for: project.id)
        return (
            AVChapterRenderer(assetsRoot: layout.root),
            ProductionRenderCache(root: layout.renderAudioURL, fileStore: fileStore),
            fileStore
        )
    }

    /// Recomputes each chapter's render state against the current cache key.
    func refreshRenderStatuses() async {
        guard let project else { return }
        let components = renderComponents(for: project)
        var statuses: [UUID: ChapterRenderState] = [:]
        for chapter in project.chapters {
            let recorded = chapter.paragraphs.contains { $0.selectedTakeID != nil }
            guard recorded else {
                statuses[chapter.id] = .notRecorded
                continue
            }
            let plan = PackagingSupport.renderPlan(for: chapter, in: project)
            let cached = try? await components.cache.cachedRender(for: plan.cacheKey)
            statuses[chapter.id] = cached != nil ? .current : .stale
        }
        renderStatuses = statuses
    }

    /// Renders every recorded chapter, chunked by chapter and cancellable
    /// (§11.2). Cached chapters are skipped, so cancelling and re-running
    /// resumes at the first incomplete chapter. Chapters with no recorded takes
    /// are never rendered — the cache list shows them as not recorded.
    func renderAllChapters() async {
        guard let project, !isRendering else { return }
        let recordedChapters = project.chapters.filter { $0.paragraphs.contains { $0.selectedTakeID != nil } }
        guard !recordedChapters.isEmpty else { return }
        isRendering = true
        renderError = nil
        renderProgress = ChunkedRenderCoordinator.Progress(completedChapterCount: 0, totalChapterCount: recordedChapters.count)
        defer { isRendering = false }
        let components = renderComponents(for: project)
        do {
            _ = try await ChunkedRenderCoordinator().render(
                chapters: recordedChapters,
                in: project,
                renderer: components.renderer,
                cache: components.cache,
                assets: components.assets,
                progress: { [weak self] p in
                    Task { @MainActor in self?.renderProgress = p }
                }
            )
            await refreshRenderStatuses()
        } catch is CancellationError {
            await refreshRenderStatuses()
        } catch {
            renderError = "Rendering stopped: \(error.localizedDescription)"
        }
    }

    /// Starts a cancellable render in the background; the assembly screen
    /// drives it and offers a Cancel control.
    func startRenderAllChapters() {
        renderTask?.cancel()
        renderTask = Task { @MainActor in
            await renderAllChapters()
        }
    }

    func cancelRendering() {
        renderTask?.cancel()
    }

    func clearRenderCache() async {
        guard let project else { return }
        let components = renderComponents(for: project)
        try? await components.cache.clear()
        await refreshRenderStatuses()
    }

    /// Free space actually needed by the recorded chapters vs what is free, for
    /// the assembly preflight card (mockup 10). Render estimates are lossless
    /// masters of the recorded takes; a rough byte estimate keeps the card
    /// truthful without decoding audio.
    var renderPreflight: (neededBytes: Int64, freeBytes: Int64)? {
        guard let project else { return nil }
        var needed: Int64 = 0
        for chapter in project.chapters {
            for paragraph in chapter.paragraphs {
                if let take = paragraph.selectedTake, !take.isArchived {
                    needed += Int64(take.assetRef.byteCount)
                }
            }
        }
        needed = needed > 0 ? needed : 1
        let free = FreeSpaceProvider.availableBytes ?? 0
        return (needed, free)
    }

    // MARK: - Imported audio (spec §10)

    var importSelection: FlowImportedAudio?
    var importPlan: AudioImportPlan?
    var importMode: AudioImportMode = .splitBySilence
    var importOrigin: FlowImportOrigin = .selfRecorded
    var importTrashOriginal = true
    var isImportingAudio = false
    var importFileURL: URL?

    /// Inspects a picked audio file: size, format, and a silence-split plan
    /// against the current project's paragraphs. The import screen reads this
    /// before anything is written (§10: storage impact stated first).
    func inspectAudioFile(_ url: URL) async {
        importError = nil
        importFileURL = url
        let decoder = RoutingAudioDecoder()
        do {
            let format = try await decoder.describe(url)
            let decoded = try await decoder.decodeToMonoFloat(url, targetSampleRate: nil)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            importSelection = FlowImportedAudio(
                sourceURL: url,
                originalSize: Int64(size),
                fileName: url.lastPathComponent,
                format: format,
                duration: decoded.duration,
                decodedSampleRate: decoded.sampleRate,
                decodedSampleCount: decoded.samples.count
            )
            rebuildImportPlan(samples: decoded.samples, sampleRate: decoded.sampleRate)
        } catch {
            importError = "Couldn't read that audio file. Try WAV, AIFF, CAF, M4A, MP3, or FLAC."
        }
    }

    /// Recomputes the assignment plan for the current mode against the decoded
    /// file.
    func rebuildImportPlan(samples: [Float], sampleRate: Double) {
        guard let project else { return }
        let targets = project.allParagraphs.filter { $0.role == .body }.map(\.id)
        importPlan = AudioImportPlanner().plan(
            samples: samples,
            sampleRate: sampleRate,
            mode: importMode,
            targetParagraphIDs: targets
        )
    }

    /// Executes the approved import: writes each planned slice as a take with
    /// the declared origin and computed metrics, then persists (§9.4 ordering:
    /// bytes durable before metadata mutation). Non-human origins carry the
    /// compliance flag the validation engine turns into a LibriVox block (§10).
    func runAudioImport() async {
        guard let selection = importSelection, let plan = importPlan, let project else { return }
        guard !isImportingAudio else { return }
        isImportingAudio = true
        importError = nil
        defer { isImportingAudio = false }

        let decoder = RoutingAudioDecoder()
        do {
            let decoded = try await decoder.decodeToMonoFloat(selection.sourceURL, targetSampleRate: nil)
            let rate = decoded.sampleRate

            for slice in plan.slices {
                try Task.checkCancellation()
                guard let paragraphID = slice.paragraphID,
                      let paragraph = project.allParagraphs.first(where: { $0.id == paragraphID }) else { continue }

                let sliceSamples = Array(decoded.samples[slice.startFrame..<min(decoded.samples.count, slice.startFrame + slice.frameCount)])
                guard !sliceSamples.isEmpty else { continue }

                let url = try Self.writeSliceCAF(sliceSamples, sampleRate: rate)
                let duration = Double(sliceSamples.count) / rate
                let metrics = AudioMetricsCalculator().metrics(for: sliceSamples, sampleRate: rate, channels: 1)
                let format = AudioFormatDescription(sampleRate: rate, channels: 1, bitDepth: 32, codec: "pcm")
                let origin = importOrigin.audioOrigin(fileName: selection.fileName)

                let chapter = project.chapters.first { $0.paragraphs.contains { $0.id == paragraphID } }
                let take = try await repository.ingestImportedSlice(
                    fileURL: url,
                    paragraphID: paragraphID,
                    projectID: project.id,
                    origin: origin,
                    metrics: metrics,
                    duration: duration,
                    format: format,
                    textHash: paragraph.textHash,
                    chapterID: chapter?.id,
                    chapterOrdinal: chapter?.ordinal
                )
                updateParagraph(paragraphID) { p in
                    p.takes.append(take)
                    p.selectedTakeID = take.id
                    p.reviewState = .approved
                    for index in p.takes.indices where p.takes[index].id != take.id {
                        p.takes[index].isArchived = true
                    }
                    p.updatedAt = repository.clock.now
                }
            }

            if importTrashOriginal {
                try? FileManager.default.removeItem(at: selection.sourceURL)
            }
            await persist()
        } catch is CancellationError {
            // Partial import stays persisted by the per-slice writes above.
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Writes a mono Float32 CAF slice so the content store can hash it.
    private static func writeSliceCAF(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-slice-\(UUID().uuidString).caf") // determinism-exempt: transient temp filename, never persisted
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: - Export

    /// The root directory exports are written into: `Application Support/Voxglass/Exports`.
    var exportsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Voxglass/Exports", isDirectory: true)
    }

    /// P7 (§12, §13.2): runs the full rule engine for `validationDestination`
    /// with the hydration + storage preflight context fed in, so the screen and
    /// the export pipeline agree about what blocks the run.
    func runValidation() async {
        guard let project else { return }
        isValidating = true
        validationError = nil
        defer { isValidating = false }
        let assets = (try? await SQLiteProductionAssetRepository(databaseURL: repository.layout(for: project.id).databaseURL).records()) ?? []
        let preflight = ExportPreflight.compute(
            project: project,
            assets: assets,
            scope: .wholeBook,
            freeBytes: FreeSpaceProvider.availableBytes
        )
        self.preflight = preflight
        validationIssues = ValidationRuleEngine().evaluate(
            project: project,
            metrics: PackagingSupport.selectedTakeMetrics(project),
            profile: DestinationProfile.profile(for: validationDestination),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly,
            context: ValidationContext(exportPreflight: preflight.exportPreflightContext)
        )
    }

    func selectValidationDestination(_ destination: DestinationID) {
        guard destination != validationDestination else { return }
        validationDestination = destination
        Task { await runValidation() }
    }

    /// ACX readiness preview for the Pro purchase sheet (mockup 14c). Validation
    /// is never gated (§2.2): a free user sees their full retail report before
    /// buying. Does not change the selected export destination.
    func acxReadinessPreview() async -> [ValidationIssue] {
        guard let project else { return [] }
        let assets = (try? await SQLiteProductionAssetRepository(databaseURL: repository.layout(for: project.id).databaseURL).records()) ?? []
        let preflight = ExportPreflight.compute(
            project: project,
            assets: assets,
            scope: .wholeBook,
            freeBytes: FreeSpaceProvider.availableBytes
        )
        return ValidationRuleEngine().evaluate(
            project: project,
            metrics: PackagingSupport.selectedTakeMetrics(project),
            profile: DestinationProfile.profile(for: .acx),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly,
            context: ValidationContext(exportPreflight: preflight.exportPreflightContext)
        )
    }

    /// Blocking issues that gate *starting* an export — the four preflight
    /// codes plus the destination's other blocking rules.
    var blockingValidationIssues: [ValidationIssue] {
        validationIssues.filter { $0.severity == .blocking }
    }

    /// P7/P8 (§13): produces the real package for `validationDestination` through
    /// the free builders or the Pro retail builder, via `ResumableExportRunner`,
    /// zips it for Save to Files, and hands it to the Submit screen. Free lanes
    /// never touch a license gate; retail consults it in the runner (§2.2).
    func runExport() async {
        guard let project, project.rights.isAttested, !isExporting else { return }
        guard blockingValidationIssues.isEmpty else {
            exportError = "Resolve the blocking validation issues before exporting."
            return
        }
        let isRetail = validationDestination == .acx || validationDestination == .appleBooksAggregator
        if isRetail {
            do {
                try await licenseGate.require(.retailPresets)
            } catch {
                exportError = "Commercial retail export is a Voxglass Narration Pro feature."
                return
            }
        }
        isExporting = true
        exportError = nil
        exportProgress = nil
        exportRunRecord = nil
        defer { isExporting = false }

        let builder: any PackageBuilder
        var options = ExportOptions(
            generatedAt: repository.clock.now,
            appVersion: "Voxglass \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1")"
        )
        switch validationDestination {
        case .librivox:
            builder = LibriVoxPackageBuilder()
        case .internetArchive:
            builder = InternetArchivePackageBuilder()
            options.includeMP3Derivatives = true
        case .acx, .appleBooksAggregator:
            builder = RetailMasterPackageBuilder(destination: validationDestination)
            options.applyMastering = true
            options.writeValidationReport = true
            options.retailSample = defaultRetailSample()
        case .personalMaster:
            exportError = "Lossless personal masters aren't wired into this build yet."
            return
        }
        let layout = repository.layout(for: project.id)
        let renderer = AVChapterRenderer(assetsRoot: layout.root)
        let assets = repository.fileStore(for: project.id)

        do {
            let outcome = try await ResumableExportRunner(store: repository.store(for: project.id)).run(
                builder: builder,
                project: project,
                renders: renderer,
                transcoder: VoxTranscoder(),
                assets: assets,
                into: exportsDirectory,
                options: options,
                progress: { [weak self] event in
                    Task { @MainActor in self?.exportProgress = event }
                }
            )
            exportRunRecord = outcome.run
            guard let bundle = outcome.bundle else {
                exportError = "Export was cancelled. Finished chapters are kept — run it again to resume."
                return
            }
            let slug = PackagingSupport.directorySlug(project.metadata.title)
            let zipURL = exportsDirectory.appendingPathComponent("\(slug)-\(builder.destination.rawValue).zip")
            let shareURL = try ExportPackageZipper.zipContents(of: bundle.rootURL, to: zipURL)
            exportBundle = NarrationExportBundle(
                directory: bundle.rootURL,
                shareURL: shareURL,
                filename: bundle.files.first { $0.role == .chapter }?.url.lastPathComponent ?? "",
                files: bundle.files.map(\.url),
                totalDuration: bundle.totalDuration
            )
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// The default retail sample: the first recorded body paragraph, ~90 seconds —
    /// the [60, 300] s retail window is enforced by validation. The export wizard
    /// offers a fixed sample in MVP; a sample picker is future work.
    private func defaultRetailSample() -> RetailSampleSelection? {
        guard let project else { return nil }
        guard let id = project.allParagraphs.first(where: { $0.selectedTakeID != nil })?.id else { return nil }
        return RetailSampleSelection(startParagraphID: id, duration: 90)
    }

    func startExport() {
        exportTask?.cancel()
        exportTask = Task { @MainActor in
            await runExport()
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// P7 (§13.3): removes the local staging for the last run once the package
    /// has been handed off to Files (mockup 14 `export.evictAfterSave`).
    func evictLastExportStaging() async {
        guard let project, let run = exportRunRecord, let outputPath = run.outputPath else { return }
        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.removeItem(at: url)
        exportRunRecord = nil
        if let zip = exportBundle?.shareURL {
            try? FileManager.default.removeItem(at: zip)
            exportBundle = nil
        }
        _ = project
    }

    private func stripProjectGutenberg(_ text: String) -> String {
        var t = text
        if let range = t.range(of: "*** START OF THE PROJECT GUTENBERG EBOOK") {
            t = String(t[range.upperBound...])
        }
        if let range = t.range(of: "*** END OF THE PROJECT GUTENBERG EBOOK") {
            t = String(t[..<range.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstHeaderLine(_ text: String, matching key: String) -> String? {
        for line in text.split(separator: "\n").prefix(40) {
            if line.hasPrefix(key) {
                return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

struct NarrationExportBundle: Equatable {
    var directory: URL
    var shareURL: URL
    var filename: String
    var files: [URL]
    var totalDuration: TimeInterval
}

// MARK: - Root

/// Presents the eight-step flow; a fresh project starts at Import (p01), an
/// existing one resumes at Record.
struct NarrationFlowRoot: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppPreferencesStore.Keys.narrationOnboardingSeen) private var narrationOnboardingSeen = false
    @State private var model: NarrationFlowModel
    @State private var showHelp = false
    @State private var confirmDelete = false
    let existing: AudiobookProject?
    let startNeed: NarrationNeed?

    init(existing: AudiobookProject? = nil, startNeed: NarrationNeed? = nil) {
        self.existing = existing
        self.startNeed = startNeed
        #if DEBUG
        // The smoke test drives the whole flow with a scripted capture
        // (spec §12.3) so recording is deterministic with no mic or audio
        // hardware — simulator audio input is unreliable since iOS 17.
        let capture: any AudioCapturing = ProcessInfo.processInfo.arguments.contains("-uiTestFakeCapture")
            ? UITestAudioCapture()
            : AudioSessionCapture()
        #else
        let capture: any AudioCapturing = AudioSessionCapture()
        #endif
        _model = State(initialValue: NarrationFlowModel(existing: existing, capture: capture))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.project != nil {
                    FlowResumeRouter(model: model)
                } else {
                    WorkImportView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 6) {
                        if model.project != nil {
                            Button {
                                confirmDelete = true
                            } label: {
                                Image(systemName: "trash")
                                    .scaledFont(size: 16, weight: .semibold)
                            }
                            .accessibilityIdentifier("narration.delete")
                        }
                        Button {
                            showHelp = true
                        } label: {
                            Image(systemName: "questionmark.circle")
                                .scaledFont(size: 17, weight: .semibold)
                        }
                        .accessibilityIdentifier("narration.help")
                    }
                }
            }
        }
        .confirmationDialog(
            model.project.map { "Delete \"\($0.metadata.title)\" and its recordings?" } ?? "Delete this narration?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Narration", role: .destructive) {
                if let project = model.project {
                    Task { await discovery.delete(project) }
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the project and its recorded takes from this device.")
        }
        .task {
            // The watch recording-remote (spec §14.3) targets this flow's active
            // recording session through the phone production relay.
            model.phoneProduction = discovery.phoneProduction
            if let startNeed {
                model.importNeed(startNeed)
                if let existing = await model.existingProject(for: startNeed) {
                    await model.resume(existing)
                } else if startNeed.work.text?.isEmpty == false {
                    await model.buildParagraphs()
                } else {
                    // Textless need: stay on Import so the error is visible
                    // instead of opening an empty recording flow.
                    model.importError = "This work doesn't have its text on this device yet. Try another short work."
                }
            }
            if !narrationOnboardingSeen {
                narrationOnboardingSeen = true
                showHelp = true
            }
        }
        .sheet(isPresented: $showHelp) {
            NarrationHelpSheet()
        }
        .onChange(of: model.project) { _, newProject in
            if let newProject {
                Task { await discovery.save(newProject) }
            }
        }
    }
}

/// First-run popup + persistent help: a brief walkthrough of the narration
/// flow. Shown once automatically, and again any time from the help button.
struct NarrationHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recording your narration")
                            .scaledFont(size: 22, weight: .heavy)
                            .foregroundStyle(Palette.ink)
                        Text("Read each paragraph aloud, one at a time. Your takes stay on this device until you finish the checklist.")
                            .scaledFont(size: 13)
                            .foregroundStyle(Palette.ink2)
                    }

                    step(1, "Tap the record button and read the paragraph on screen.", icon: "record.circle")
                    step(2, "Tap stop when you're done. The take appears below the transport.", icon: "stop.fill")
                    step(3, "Listen back with play. Tap \"Accept & Next\" to move on, or flag a paragraph to re-record it later.", icon: "checkmark.circle.fill")
                    step(4, "After the last paragraph, review the list, add title and rights, and produce your files.", icon: "list.bullet")
                    step(5, "Encoding to MP3/FLAC happens on your iPhone. Save the finished package to Files and submit it yourself.", icon: "iphone")

                    Text("If a recording doesn't start, check that the microphone is allowed in Settings → Privacy → Microphone.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink3)

                    Button {
                        dismiss()
                    } label: {
                        Text("Got it")
                            .scaledFont(size: 15, weight: .heavy)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Color(hex: 0x21170B))
                    }
                    .buttonStyle(.plain)
                    .tactileTap()
                    .accessibilityIdentifier("narration.helpSheet.dismiss")
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("narration.helpSheet")
        }
        .presentationDetents([.medium, .large])
    }

    private func step(_ number: Int, _ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Palette.brass.opacity(0.14))
                Image(systemName: icon)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Palette.brass)
            }
            .frame(width: 32, height: 32)
            Text(LocalizedStringKey(text))
                .scaledFont(size: 13.5)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
        .padding(12)
        .glassSurface(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
    }
}

private struct FlowResumeRouter: View {
    @Bindable var model: NarrationFlowModel

    var body: some View {
        if model.project != nil {
            // §15.5: "Record next" = first paragraph with no selected take, or
            // the first needsPickup when everything is recorded.
            if let next = model.recordNextParagraphID {
                RecordView(model: model, paragraphID: next)
            } else if !model.readyToAssemble {
                ReviewView(model: model)
            } else if !model.rightsAttested {
                AssembleView(model: model)
            } else {
                SubmitView(model: model)
            }
        }
    }
}

// MARK: - p01 Import

struct WorkImportView: View {
    @Bindable var model: NarrationFlowModel
    @Environment(DiscoveryEnvironment.self) private var discovery
    @State private var showNeedsPicker = false
    @State private var showPaste = false
    @State private var showGutenberg = false
    @State private var pickedFileURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Narration")
                    .scaledFont(size: 26, weight: .heavy)
                    .foregroundStyle(Palette.ink)
                Text("Record a public-domain work — a poem, a short story, or a whole book, chapter by chapter.")
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.ink2)

                importOption(icon: "🎙️", title: "From a Narration Need", tag: "Recommended", caption: "This week's poem, or a work that needs a reader", id: "import.fromNeed") {
                    showNeedsPicker = true
                }
                importOption(icon: "📝", title: "Paste text", caption: "Paste a poem or short piece", id: "import.paste") {
                    showPaste = true
                }
                importOption(icon: "📄", title: "Import a file", caption: "EPUB, TXT, Markdown, or DOCX from Files", id: "import.files") {
                    presentFilesPicker()
                }
                importOption(icon: "🌐", title: "Fetch from Project Gutenberg", caption: "Paste a gutenberg.org link or ebook number", id: "import.gutenberg") {
                    showGutenberg = true
                }

                if model.isImporting {
                    HStack(spacing: 8) {
                        ProgressView().tint(Palette.brass)
                        Text("Fetching…").scaledFont(size: 12).foregroundStyle(Palette.ink2)
                    }
                    .padding(.top, 8)
                }
                if let error = model.importError {
                    Text(error).scaledFont(size: 12).foregroundStyle(Palette.danger)
                }

                Text(LegalStrings.noCopyrightDetermination)
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .sheet(isPresented: $showNeedsPicker) {
            NeedPickerSheet(model: model)
        }
        .sheet(isPresented: $showPaste) {
            PasteSheet(model: model)
        }
        .sheet(isPresented: $showGutenberg) {
            GutenbergSheet(model: model)
        }
        .fileImporter(isPresented: Binding(get: { pickedFileURL != nil }, set: { if !$0 { pickedFileURL = nil } }), allowedContentTypes: importContentTypes) { result in
            if case .success(let url) = result {
                importFile(url)
            }
        }
    }

    /// The file types the import picker accepts, mirroring
    /// `SourceImporterRegistry`: EPUB, plain text, Markdown, and DOCX.
    private var importContentTypes: [UTType] {
        var types: [UTType] = [.epub, .plainText, .text]
        if let markdown = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx") {
            types.append(docx)
        }
        return types
    }

    private func importOption(icon: String, title: String, tag: String? = nil, caption: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color(hex: 0x2A2417), Color(hex: 0x5A4A2B)], startPoint: .top, endPoint: .bottom))
                    Text(icon).scaledFont(size: 20)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(size: 15, weight: .bold).foregroundStyle(Palette.ink)
                        if let tag {
                            Text(tag).scaledFont(size: 10, weight: .bold).foregroundStyle(Palette.brass)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Palette.brass.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(Palette.brass.opacity(0.5), lineWidth: 1))
                        }
                    }
                    Text(caption).scaledFont(size: 12).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(size: 12).foregroundStyle(Palette.ink3)
            }
            .padding(14)
            .glassSurface(cornerRadius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tactileTap()
        .accessibilityIdentifier(id)
    }

    private func presentFilesPicker() {
        pickedFileURL = URL(fileURLWithPath: "/") // triggers the sheet
    }

    /// Imports a source document through `SourceImporterRegistry` and builds a
    /// multi-chapter project from it (P5: file imports keep their chapter
    /// structure instead of being flattened).
    private func importFile(_ url: URL) {
        Task {
            model.isImporting = true
            defer { model.isImporting = false }
            do {
                guard let importer = SourceImporterRegistry.importer(for: url) else {
                    model.importError = "Couldn't find an importer for that file."
                    return
                }
                let doc = try await importer.extract(from: url)
                model.draftTitle = doc.title ?? ""
                model.draftAuthor = doc.author ?? ""
                model.setSource(url.lastPathComponent)
                await model.buildFromDocument(doc)
            } catch {
                model.importError = "Couldn't read that file."
            }
        }
    }
}

private struct NeedPickerSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(DiscoveryEnvironment.self) private var discovery
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let needs = discovery.needs.filter { $0.recordableOniOS }
            List {
                if needs.isEmpty {
                    Text("No ready-to-record needs with embedded text right now — try Paste text.")
                }
                ForEach(needs.prefix(20)) { need in
                    Button {
                        model.importNeed(need)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(need.work.title).font(.headline)
                            Text("\(need.work.author) · \(shortDuration(need.work.estSeconds))").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("From a Need")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PasteSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("metadata.title")
                TextField("Author", text: $author).accessibilityIdentifier("metadata.author")
                TextEditor(text: $text).frame(minHeight: 200)
            }
            .navigationTitle("Paste text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this text") {
                        model.importPastedText(title: title, author: author, text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct GutenbergSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ebook number or gutenberg.org link", text: $identifier)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("import.gutenberg")
                } footer: {
                    Text("Fetch is best-effort and offline-friendly: if it fails, Paste text instead.")
                }
            }
            .navigationTitle("Project Gutenberg")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fetch") {
                        let id = identifier
                        dismiss()
                        Task { await model.fetchGutenberg(identifier: id) }
                    }
                    .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
