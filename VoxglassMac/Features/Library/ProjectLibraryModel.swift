import Foundation
import Observation
import VoxglassCore

@MainActor
@Observable
public final class ProjectLibraryModel {
    public var store: any ProductionStore
    public private(set) var recents: RecentsStore
    public var showOpenPanel = false
    public var pendingProjectURL: URL?
    public private(set) var error: String?
    /// A stale advisory lock was found — "Open anyway" needs confirmation.
    public private(set) var staleLockPrompt: (lock: PackageLock, url: URL)?
    /// The project is already open in this app — focus its window.
    public private(set) var alreadyOpenProjectURL: URL?
    public var onProjectOpened: ((AudiobookProject, any ProductionStore) -> Void)?
    public var onAutosaveRecoveryAvailable: ((URL) -> Void)?
    public var onProjectAlreadyOpen: ((URL) -> Void)?

    private let seed: UITestSeed?
    private let isTestEnvironment: Bool

    public init(
        store: any ProductionStore = InMemoryProductionStore(),
        recents: RecentsStore = RecentsStore(),
        seed: UITestSeed? = nil,
        isTestEnvironment: Bool = false
    ) {
        self.store = store
        self.recents = recents
        self.seed = seed
        self.isTestEnvironment = isTestEnvironment
    }

    /// The advisory-lock entry point (§8.3): a live lock focuses the existing
    /// window; a stale lock offers "Open anyway"; otherwise the project opens
    /// and the lock is written.
    public func openProject(at url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            error = "Cannot access project at \(url.lastPathComponent)"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let package = try await ProjectPackage.open(url)

            if let lock = PackageLockFile.read(from: url) {
                if PackageLockFile.isHeldHere(lock) {
                    alreadyOpenProjectURL = url
                    onProjectAlreadyOpen?(url)
                    return
                }
                staleLockPrompt = (lock, url)
                return
            }

            try await openUnchecked(package, at: url)
        } catch {
            self.error = "Failed to open project: \(error.localizedDescription)"
        }
    }

    /// Proceeds past a stale lock (mockup `18`).
    public func confirmOpenAnyway() async {
        guard let prompt = staleLockPrompt else { return }
        staleLockPrompt = nil
        guard prompt.url.startAccessingSecurityScopedResource() else {
            error = "Cannot access project at \(prompt.url.lastPathComponent)"
            return
        }
        defer { prompt.url.stopAccessingSecurityScopedResource() }
        do {
            let package = try await ProjectPackage.open(prompt.url)
            try await openUnchecked(package, at: prompt.url)
        } catch {
            self.error = "Failed to open project: \(error.localizedDescription)"
        }
    }

    public func dismissStaleLockPrompt() {
        staleLockPrompt = nil
    }

    public func dismissAlreadyOpen() {
        alreadyOpenProjectURL = nil
    }

    private func openUnchecked(_ package: ProjectPackage, at url: URL) async throws {
        try PackageLockFile.write(to: url)
        let sqlite = SQLiteProductionStore(databaseURL: package.databaseURL)
        let project = try await sqlite.load()
        self.store = sqlite
        pendingProjectURL = url
        let manifest = try? ProjectPackage.readManifest(url)
        recents.add(url: url, manifest: manifest, summary: try? await sqlite.summary())
        onProjectOpened?(project, sqlite)
        if !package.integrityFindings.isEmpty {
            let blocking = package.integrityFindings.filter { $0.severity == .blocking }.count
            if blocking > 0 {
                error = "Project opened with \(blocking) blocking integrity finding(s)."
            }
        }
        if package.hasAutosaveRecovery {
            onAutosaveRecoveryAvailable?(url)
        }
    }

    /// Refreshes the cached snapshot (§8.1) — called when a project closes and
    /// after any sync fetch.
    public func refreshSummary(project: AudiobookProject, store: any ProductionStore) async {
        guard let url = pendingProjectURL,
              let summary = try? await store.summary() else { return }
        recents.updateSummary(summary, forURL: url)
    }

    /// Removes the advisory lock (window close / app termination, §8.3).
    public func releaseLock(for url: URL?) {
        guard let url else { return }
        PackageLockFile.remove(from: url)
    }

    public func newProject(title: String, author: String, narrator: String,
                            purpose: ProjectPurpose, destination: DestinationID,
                            rights: RightsEvidence? = nil) -> AudiobookProject {
        let ids = UUIDGenerator()
        let clock = SystemClock()
        let rec = RecordingDefaults()
        let asm = AssemblySettings()
        let profile = ProductionProfile(
            purpose: purpose,
            recording: rec,
            assembly: asm,
            intendedDestination: destination
        )
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: title, author: author, narrator: narrator),
            rights: rights ?? RightsEvidence(basis: purpose == .publicDomainCommunity ? .publicDomainUS : .personalUseOnly),
            profile: profile,
            chapters: [],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
        return project
    }

    public func createAndPersistProject(
        title: String, author: String, narrator: String,
        purpose: ProjectPurpose, destination: DestinationID,
        rights: RightsEvidence? = nil,
        at directory: URL,
        ids: any IDGenerator = UUIDGenerator(),
        clock: any Clock = SystemClock()
    ) async throws -> AudiobookProject {
        let project = newProject(
            title: title, author: author, narrator: narrator,
            purpose: purpose, destination: destination,
            rights: rights
        )

        let package = try await ProjectPackage.create(
            title: title, author: author, narrator: narrator,
            at: directory, clock: clock, ids: ids
        )

        let sqlite = SQLiteProductionStore(databaseURL: package.databaseURL)
        try await sqlite.save(project)

        self.store = sqlite
        pendingProjectURL = directory
        recents.add(url: directory, manifest: try? ProjectPackage.readManifest(directory), summary: try? await sqlite.summary())
        return project
    }

    public func seedIfNeeded() async {
        guard isTestEnvironment, let seed else { return }
        switch seed {
        case .empty:
            recents.clear()
        case .onePreviewProject, .oneFlaggedQueue, .watchQueue, .librivoxReady:
            if recents.recentURLs.isEmpty {
                #if DEBUG
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-test-seed")
                try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                let projectURL = tempDir.appendingPathComponent("seed.voxproject")
                try? FileManager.default.removeItem(at: projectURL)
                do {
                    let project = try await createAndPersistProject(
                        title: "Seed Project", author: "Author", narrator: "Narrator",
                        purpose: .personal, destination: .librivox,
                        at: projectURL
                    )
                    onProjectOpened?(project, store)
                } catch {
                    self.error = "Failed to seed project: \(error.localizedDescription)"
                }
                #endif
            }
        }
    }

    public func dismissError() {
        error = nil
    }
}
