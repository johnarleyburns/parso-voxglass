import Foundation
import Observation
import VoxglassCore

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
    public private(set) var takes: [Take] = []
    public let meter = RecordingMeter()
    public var error: String?
    public private(set) var autosaveDirectory: URL?

    public var canRecord: Bool { phase == .idle || isPreRoll }

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

    public init(
        capture: any AudioCapturing,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        projectID: UUID,
        packageRoot: URL? = nil
    ) {
        self.capture = capture
        self.store = store
        self.assets = assets
        self.projectID = projectID
        self.packageRoot = packageRoot
    }

    public func loadProject() async {
        do {
            project = try await store.load()
        } catch {
            self.error = "Failed to load project: \(error.localizedDescription)"
        }
    }

    public func prepare() async {
        do {
            try await capture.prepare(device: nil, format: project?.profile.recording ?? RecordingDefaults())
            phase = .idle
        } catch {
            self.error = "Failed to prepare capture: \(error.localizedDescription)"
            phase = .idle
        }
    }

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

        do {
            let captured = try await capture.stopRecording()
            let take = try await ingestTake(from: captured, paragraphID: paragraphID)
            takes.append(take)
            deleteAutosaveSession()
            pendingTakeID = nil
            phase = .idle
            Log.capture.info("recording finalized (take \(take.id.uuidString), \(Int(take.duration))s, asset \(take.assetRef.sha256.prefix(12)))")
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
        let take = Take(
            id: pendingTakeID ?? UUID(),
            paragraphID: paragraphID,
            assetRef: assetRef,
            origin: .recorded,
            recordedAt: Date(),
            duration: captured.duration,
            format: captured.format,
            textHashAtRecording: project?.allParagraphs.first(where: { $0.id == paragraphID })?.textHash ?? ""
        )
        try await store.insertTake(take)
        return take
    }
}
