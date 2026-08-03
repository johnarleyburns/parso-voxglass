import Foundation
import Observation
import VoxglassCore

/// The interruption banner copy from mockup `17`.
public struct CaptureInterruptionBanner: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case deviceChanged(name: String)
        case sleep
        case diskFull
    }

    public let kind: Kind
    /// The take the capture finalized before the interruption; nil when the
    /// write failed so early that no audio exists.
    public let takeID: UUID?

    public init(kind: Kind, takeID: UUID?) {
        self.kind = kind
        self.takeID = takeID
    }

    public var title: String {
        switch kind {
        case .deviceChanged: "Your input device changed."
        case .sleep: "Your Mac went to sleep."
        case .diskFull: "The disk filled up while recording."
        }
    }

    public var message: String {
        switch kind {
        case .deviceChanged, .sleep: "The take was saved."
        case .diskFull: "Everything recorded up to that point was saved."
        }
    }
}

@Observable @MainActor
public final class RecordingModel {
    public enum Phase: Equatable {
        case idle
        case preRoll(countdown: TimeInterval)
        case recording
        case stopping
    }

    public private(set) var phase: Phase = .idle
    public private(set) var currentParagraphID: UUID?
    /// Session aggregate of every take recorded (or imported) in this run,
    /// across paragraphs — never reset on paragraph change.
    public private(set) var takes: [Take] = []
    public let meter = RecordingMeter()
    public var error: String?
    public private(set) var autosaveDirectory: URL?
    /// The take currently selected for the focused paragraph.
    public var selectedTakeID: UUID?
    /// Async quality metrics, keyed by take ID (§11.2 quality panel).
    public private(set) var takeMetrics: [UUID: AudioQualityMetrics] = [:]
    public private(set) var isComputingQuality = false
    public private(set) var overrunWarning: String?
    /// Set when the capture had to finalize a take outside the normal stop
    /// path (device change, sleep, disk full) — mockup `17`.
    public private(set) var interruptionBanner: CaptureInterruptionBanner?
    public private(set) var captureError: CaptureError?

    public var canRecord: Bool { phase == .idle || isPreRoll }

    public var currentParagraphTakes: [Take] {
        guard let currentParagraphID else { return [] }
        return takes.filter { $0.paragraphID == currentParagraphID }
    }

    private var isPreRoll: Bool {
        if case .preRoll = phase { return true }
        return false
    }

    private let capture: any AudioCapturing
    private var levelTask: Task<Void, Never>?
    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    private let projectID: UUID
    private let packageRoot: URL?
    private var project: AudiobookProject?
    private var pendingTakeID: UUID?
    private var pendingSessionURL: URL?
    private let player: (any SegmentPlayer)?
    private let metrics: (any AudioMetricsCalculating)?
    /// UI preferences that shape recording behavior (auto-select, skip-on-advance).
    public var settings = StudioSettings()
    public let undo: StudioUndo

    public init(
        capture: any AudioCapturing,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        projectID: UUID,
        packageRoot: URL? = nil,
        player: (any SegmentPlayer)? = nil,
        metrics: (any AudioMetricsCalculating)? = nil,
        undo: StudioUndo = StudioUndo()
    ) {
        self.capture = capture
        self.store = store
        self.assets = assets
        self.projectID = projectID
        self.packageRoot = packageRoot
        self.player = player
        self.metrics = metrics
        self.undo = undo
    }

    // MARK: - Project / paragraph focus

    public func loadProject() async {
        do {
            project = try await store.load()
        } catch {
            self.error = "Failed to load project: \(error.localizedDescription)"
        }
    }

    /// Focuses the workspace on `paragraphID`: loads its takes and restores
    /// the selected take.
    public func loadParagraph(_ id: UUID) async {
        currentParagraphID = id
        if project == nil { await loadProject() }
        guard let paragraph = project?.allParagraphs.first(where: { $0.id == id }) else { return }
        if !paragraph.takes.isEmpty {
            // Reconcile session aggregate with the store so the list is fresh
            // even after the workspace was opened late.
            for take in paragraph.takes where !takes.contains(where: { $0.id == take.id }) {
                takes.append(take)
            }
        }
        selectedTakeID = paragraph.selectedTakeID ?? paragraph.takes.last?.id
    }

    public func prepare() async {
        do {
            try await capture.prepare(device: nil, format: project?.profile.recording ?? RecordingDefaults())
            captureError = nil
            phase = .idle
        } catch {
            captureError = error as? CaptureError
            self.error = "Failed to prepare capture: \(error.localizedDescription)"
            phase = .idle
        }
    }

    // MARK: - Capture interruptions (§11.2 rules 6 and 8, mockup `17`)

    /// Consumes a capture-finalized take (device change, sleep, disk full):
    /// ingests it as a complete take, preserves it, and surfaces the banner.
    /// "Never lose a take" is the product's first principle (§0.4).
    public func handleCaptureInterruption(_ interruption: CaptureInterruption) async {
        var bannerTakeID: UUID?
        if let captured = interruption.take {
            do {
                let assetRef = try await assets.ingest(
                    fileAt: captured.fileURL,
                    ext: "wav",
                    contentType: "audio/wav",
                    subdirectory: .original,
                    moving: true
                )
                // During a live take `currentParagraphID` is set; the fallback
                // recovers the paragraph from the autosave take filename
                // (`Autosave/takes/<uuid>.wav`).
                let paragraphID = currentParagraphID
                    ?? project?.allParagraphs.first?.id
                    ?? UUID(uuidString: captured.fileURL.deletingPathExtension().lastPathComponent)
                    ?? UUID()
                let recordedText = project?.allParagraphs.first(where: { $0.id == paragraphID })?.text ?? ""
                let take = Take(
                    id: UUID(),
                    paragraphID: paragraphID,
                    assetRef: assetRef,
                    origin: .recorded,
                    recordedAt: Date(),
                    duration: captured.duration,
                    format: captured.format,
                    textHashAtRecording: project?.allParagraphs.first(where: { $0.id == paragraphID })?.textHash ?? TextNormalizer.hash(recordedText)
                )
                try await store.insertTake(take)
                takes.append(take)
                ScriptEditorModel.sharedRecordedTexts[paragraphID] = recordedText
                if settings.autoSelectNewestTake {
                    await selectTake(take.id, forParagraph: paragraphID, registerUndo: false)
                }
                bannerTakeID = take.id
            } catch {
                self.error = "Failed to preserve interrupted take: \(error.localizedDescription)"
            }
        }
        let bannerKind: CaptureInterruptionBanner.Kind
        switch interruption.kind {
        case .deviceChanged(let name): bannerKind = .deviceChanged(name: name)
        case .sleep: bannerKind = .sleep
        case .diskFull: bannerKind = .diskFull
        }
        interruptionBanner = CaptureInterruptionBanner(
            kind: bannerKind,
            takeID: bannerTakeID
        )
    }

    public func dismissInterruptionBanner() {
        interruptionBanner = nil
    }

    /// Resumes recording on the same paragraph after an interruption.
    public func resumeAfterInterruption() async {
        interruptionBanner = nil
        guard let paragraphID = currentParagraphID else { return }
        await startRecording(paragraphID: paragraphID)
    }

    // MARK: - Recording transport

    public func startRecording(paragraphID: UUID) async {
        currentParagraphID = paragraphID
        let preRoll = project?.profile.recording.preRollSeconds ?? 0

        // The capture returns to .idle after each take; re-prepare so a
        // sequential flow can record paragraph after paragraph without loss.
        do {
            try await capture.prepare(device: nil, format: project?.profile.recording ?? RecordingDefaults())
        } catch {
            self.error = "Failed to prepare capture: \(error.localizedDescription)"
            phase = .idle
            currentParagraphID = nil
            return
        }

        if preRoll > 0 {
            phase = .preRoll(countdown: preRoll)
            do {
                try await Task.sleep(for: .seconds(preRoll))
            } catch {
                // Cancelled during pre-roll: do not start a recording.
                phase = .idle
                currentParagraphID = nil
                return
            }
        }

        do {
            let autosaveDir = try ensureAutosaveDirectory()
            let fileName = "\(UUID().uuidString).wav"
            let fileURL = autosaveDir.appendingPathComponent(fileName)

            pendingTakeID = UUID()
            try writeAutosaveSession(fileName: fileName, format: project?.profile.recording ?? RecordingDefaults())

            meter.reset()
            do {
                try await capture.startRecording(to: fileURL)
            } catch {
                deleteAutosaveSession()
                pendingTakeID = nil
                throw error
            }
            phase = .recording

            Log.capture.info("recording started (paragraph \(paragraphID.uuidString), preRoll \(preRoll)s)")
            startLevelUpdates()
        } catch {
            self.error = "Failed to start recording: \(error.localizedDescription)"
            phase = .idle
        }
    }

    public func stopRecording() async {
        guard phase == .recording, let paragraphID = currentParagraphID else { return }
        phase = .stopping
        levelTask?.cancel()
        levelTask = nil

        let previousSelection = project?.allParagraphs.first(where: { $0.id == paragraphID })?.selectedTakeID
        do {
            let captured = try await capture.stopRecording()
            let take = try await ingestTake(from: captured, paragraphID: paragraphID)
            takes.append(take)
            deleteAutosaveSession()
            pendingTakeID = nil
            phase = .idle
            Log.capture.info("recording finalized (take \(take.id.uuidString), \(Int(take.duration))s, asset \(take.assetRef.sha256.prefix(12)))")

            // §8.4: recording is never undoable — undo after a record
            // reselects the previously selected take and destroys nothing.
            let takeID = take.id
            undo.register(actionName: "Record Take") { [weak self] in
                try? await self?.store.setSelectedTake(previousSelection, forParagraph: paragraphID)
            } redo: {}

            if settings.autoSelectNewestTake {
                await selectTake(takeID, forParagraph: paragraphID, registerUndo: false)
            }
            await computeQuality(for: takeID)
        } catch {
            self.error = "Failed to stop recording: \(error.localizedDescription)"
            phase = .idle
        }
    }

    public func cancelRecording() async {
        levelTask?.cancel()
        levelTask = nil
        await capture.cancelRecording()
        deleteAutosaveSession()
        pendingTakeID = nil
        phase = .idle
    }

    public func startMonitoring() async {
        do {
            try await capture.startMonitoring()
        } catch {
            self.error = "Failed to start monitoring: \(error.localizedDescription)"
        }
    }

    public func stopMonitoring() async {
        await capture.stopMonitoring()
    }

    /// Retake: discards nothing — just starts a new take on the same paragraph.
    public func retake() async {
        guard let currentParagraphID else { return }
        await startRecording(paragraphID: currentParagraphID)
    }

    // MARK: - Take actions (§8.4: select take, archive take)

    public func selectTake(_ takeID: UUID?, forParagraph paragraphID: UUID? = nil) async {
        let pid = paragraphID ?? currentParagraphID ?? project?.allParagraphs.first?.id
        guard let pid else { return }
        await selectTake(takeID, forParagraph: pid, registerUndo: true)
    }

    private func selectTake(_ takeID: UUID?, forParagraph pid: UUID, registerUndo: Bool) async {
        let previous = project?.allParagraphs.first(where: { $0.id == pid })?.selectedTakeID
        do {
            try await store.setSelectedTake(takeID, forParagraph: pid)
            selectedTakeID = takeID
            if registerUndo {
                let previousSelection = previous
                undo.register(actionName: "Select Take") { [weak self] in
                    try? await self?.store.setSelectedTake(previousSelection, forParagraph: pid)
                } redo: { [weak self] in
                    try? await self?.store.setSelectedTake(takeID, forParagraph: pid)
                }
            }
        } catch {
            self.error = "Failed to select take: \(error.localizedDescription)"
        }
    }

    public func archiveCurrentTake() async {
        guard let takeID = selectedTakeID, let paragraphID = currentParagraphID else { return }
        let wasArchived = currentParagraphTakes.first { $0.id == takeID }?.isArchived ?? false
        do {
            try await store.archiveTake(takeID, archived: !wasArchived)
            if let index = takes.firstIndex(where: { $0.id == takeID }) {
                takes[index].isArchived = !wasArchived
            }
            undo.register(actionName: wasArchived ? "Unarchive Take" : "Archive Take") { [weak self] in
                try? await self?.store.archiveTake(takeID, archived: wasArchived)
            } redo: { [weak self] in
                try? await self?.store.archiveTake(takeID, archived: !wasArchived)
            }
        } catch {
            self.error = "Failed to archive take: \(error.localizedDescription)"
        }
    }

    /// §11.4: accept the current take and advance to the next paragraph.
    public func acceptAndAdvance(advanceTo: @escaping (UUID?) -> Void) async {
        if selectedTakeID == nil, let newest = currentParagraphTakes.last {
            await selectTake(newest.id, forParagraph: currentParagraphID)
        }
        advanceTo(nextParagraphID())
    }

    /// §11.4 ⌘Return: flag the paragraph and advance. Emits a `.flag` event —
    /// never a direct state write (§14.1).
    public func flagAndAdvance(advanceTo: @escaping (UUID?) -> Void) async {
        if let paragraphID = currentParagraphID {
            let event = ReviewEvent(projectID: projectID, paragraphID: paragraphID, type: .flag, device: .mac)
            try? await store.appendEvents([event])
            let folder = ReviewEventFolder()
            let states = currentStates
            let result = folder.fold([event], into: states)
            for (pid, state) in result.states {
                try? await store.setReviewState(state, forParagraph: pid)
            }
            for note in result.notesToInsert {
                try? await store.insertNote(note)
            }
        }
        advanceTo(nextParagraphID())
    }

    public func nextParagraphID() -> UUID? {
        guard let project, let current = currentParagraphID else { return nil }
        let all = project.allParagraphs
        guard let index = all.firstIndex(where: { $0.id == current }) else { return nil }
        var next = index + 1
        while next < all.count, all[next].selectedTakeID != nil, settings.skipRecordedOnAdvance {
            next += 1
        }
        guard next < all.count else { return nil }
        return all[next].id
    }

    public func previousParagraphID() -> UUID? {
        guard let project, let current = currentParagraphID else { return nil }
        let all = project.allParagraphs
        guard let index = all.firstIndex(where: { $0.id == current }), index > 0 else { return nil }
        return all[index - 1].id
    }

    // MARK: - Playback (§11.4 ⌥Space / ⇧Space)

    public func playSelectedTake() async {
        guard let player, let takeID = selectedTakeID, let paragraphID = currentParagraphID else { return }
        guard let paragraph = project?.allParagraphs.first(where: { $0.id == paragraphID }),
              let take = paragraph.takes.first(where: { $0.id == takeID }),
              let chapter = project?.chapters.first(where: { $0.paragraphs.contains(where: { $0.id == paragraphID }) }) else { return }
        let segment = PlaybackSegment(
            paragraphID: paragraphID,
            chapterID: chapter.id,
            globalOrdinal: paragraph.ordinal,
            assetRef: take.assetRef,
            trim: 0..<take.duration,
            text: paragraph.text,
            reviewState: paragraph.reviewState
        )
        do {
            try await player.load([segment])
            try await player.play()
        } catch {
            self.error = "Playback failed: \(error.localizedDescription)"
        }
    }

    public func playInContext() async {
        guard let player, let project, let current = currentParagraphID else { return }
        let all = project.allParagraphs
        guard let index = all.firstIndex(where: { $0.id == current }) else { return }
        let from = max(0, index - 1)
        let to = min(all.count - 1, index + 1)
        guard let chapter = project.chapters.first(where: { $0.paragraphs.contains(where: { $0.id == current }) }) else { return }
        let mode = PlaybackMode.paragraphRange(chapterID: chapter.id, from: from, to: to)
        let segments = SegmentQueueBuilder().build(mode, from: project, settings: project.profile.assembly)
        guard !segments.isEmpty else { return }
        do {
            try await player.load(segments)
            try await player.play()
        } catch {
            self.error = "Playback failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Quality panel (§11.2)

    public func computeQuality(for takeID: UUID) async {
        guard let metrics else { return }
        isComputingQuality = true
        defer { isComputingQuality = false }
        guard let take = takes.first(where: { $0.id == takeID }) else { return }
        do {
            if let url = try? assetURL(for: take) {
                let m = try await metrics.metrics(for: url)
                takeMetrics[takeID] = m
                try? await store.setTakeMetrics(m, forTake: takeID)
            }
        } catch {
            self.error = "Quality analysis failed: \(error.localizedDescription)"
        }
    }

    public func metrics(for takeID: UUID) -> AudioQualityMetrics? {
        takeMetrics[takeID]
    }

    private func assetURL(for take: Take) throws -> URL {
        // The asset lives under the package's Assets tree; FileAssetStore
        // resolves relative paths. Falls back to a direct probe.
        if let packageRoot, !take.assetRef.relativePath.isEmpty {
            let url = packageRoot.appendingPathComponent(take.assetRef.relativePath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw CaptureError.invalidState
    }

    // MARK: - Import WAV as take (§11.4 record.importWAV)

    public func importWAV(at url: URL) async {
        guard let paragraphID = currentParagraphID else { return }
        do {
            let assetRef = try await assets.ingest(
                fileAt: url,
                ext: "wav",
                contentType: "audio/wav",
                subdirectory: .original,
                moving: true
            )
            let format = AudioFormatDescription(sampleRate: 48_000, channels: 1, bitDepth: 24, codec: "pcm")
            let take = Take(
                id: UUID(),
                paragraphID: paragraphID,
                assetRef: assetRef,
                origin: .importedHuman(sourceFilename: url.lastPathComponent),
                recordedAt: Date(),
                duration: try await duration(of: url),
                format: format,
                textHashAtRecording: project?.allParagraphs.first(where: { $0.id == paragraphID })?.textHash ?? ""
            )
            try await store.insertTake(take)
            takes.append(take)
            await selectTake(take.id, forParagraph: paragraphID)
            await computeQuality(for: take.id)
        } catch {
            self.error = "Failed to import WAV: \(error.localizedDescription)"
        }
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        guard let metrics else { return 0 }
        let m = try await metrics.metrics(for: url)
        return m.duration
    }

    // MARK: - Internals

    private func startLevelUpdates() {
        levelTask = Task { [weak self, meter] in
            guard let self else { return }
            for await levels in self.capture.levels {
                guard !Task.isCancelled else { break }
                await MainActor.run { meter.update(from: levels) }
            }
        }
    }

    private func ensureAutosaveDirectory() throws -> URL {
        if let autosaveDirectory { return autosaveDirectory }
        let base: URL
        if let pkgRoot = pendingPackageRoot() {
            base = pkgRoot.appendingPathComponent("Autosave/takes", isDirectory: true)
        } else {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("Voxglass/Autosave/takes", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        autosaveDirectory = base
        return base
    }

    private func pendingPackageRoot() -> URL? {
        if let packageRoot { return packageRoot }
        // The project's package root is the store's database URL's parent when
        // the store is backed by a .voxproject database (project.sqlite).
        guard let sqlite = store as? SQLiteProductionStore else { return nil }
        let dbURL = sqlite.databaseURL
        guard dbURL.lastPathComponent == "project.sqlite" else { return nil }
        return dbURL.deletingLastPathComponent()
    }

    private func writeAutosaveSession(fileName: String, format: RecordingDefaults) throws {
        guard let pkgRoot = pendingPackageRoot(), let takeID = pendingTakeID, let paragraphID = currentParagraphID else {
            return
        }
        let chapterID = project?.allParagraphs.first(where: { $0.id == paragraphID }).flatMap { para in
            project?.chapters.first(where: { $0.paragraphs.contains(where: { $0.id == para.id }) })?.id
        }
        let session = AutosaveSession(
            takeID: takeID,
            paragraphID: paragraphID,
            chapterID: chapterID,
            filePath: "Autosave/takes/\(fileName)",
            format: AutosaveSession.Format(
                sampleRate: format.sampleRate,
                channels: 1,
                bitDepth: format.bitDepth
            ),
            startedAt: Date().timeIntervalSince1970,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
        let sessionURL = pkgRoot.appendingPathComponent("Autosave/session.json")
        try AutosaveSessionFile.write(session, to: sessionURL)
        pendingSessionURL = sessionURL
    }

    private func deleteAutosaveSession() {
        if let sessionURL = pendingSessionURL {
            AutosaveSessionFile.delete(at: sessionURL)
            pendingSessionURL = nil
        } else if let pkgRoot = pendingPackageRoot() {
            AutosaveSessionFile.delete(at: pkgRoot.appendingPathComponent("Autosave/session.json"))
        }
    }

    private func ingestTake(from captured: CapturedTake, paragraphID: UUID) async throws -> Take {
        let assetRef = try await assets.ingest(
            fileAt: captured.fileURL,
            ext: "wav",
            contentType: "audio/wav",
            subdirectory: .original,
            moving: true
        )
        let recordedText = project?.allParagraphs.first(where: { $0.id == paragraphID })?.text ?? ""
        let take = Take(
            id: pendingTakeID ?? UUID(),
            paragraphID: paragraphID,
            assetRef: assetRef,
            origin: .recorded,
            recordedAt: Date(),
            duration: captured.duration,
            format: captured.format,
            textHashAtRecording: project?.allParagraphs.first(where: { $0.id == paragraphID })?.textHash ?? TextNormalizer.hash(recordedText)
        )
        try await store.insertTake(take)
        // Feed the drift classifier (spec §9.5) while the session is alive.
        ScriptEditorModel.sharedRecordedTexts[paragraphID] = recordedText
        return take
    }

    private var currentStates: [UUID: ReviewState] {
        var states: [UUID: ReviewState] = [:]
        for paragraph in project?.allParagraphs ?? [] {
            states[paragraph.id] = paragraph.reviewState
        }
        return states
    }
}
