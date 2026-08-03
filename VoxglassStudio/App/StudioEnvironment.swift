import Foundation
import Observation
import VoxglassCore

// MARK: - StudioEnvironment

@MainActor
@Observable
public final class StudioEnvironment {
    // ── Service slots (§4.3). Injected by the composition root (`.test` /
    //    `.live`), never constructed per-route.
    public let capture: any AudioCapturing
    public let metrics: any AudioMetricsCalculating
    /// The player is rebuilt when a project opens (it must be rooted at the
    /// project's asset store).
    public var player: any SegmentPlayer
    public let transcoder: any AudioTranscoding
    public let sync: ProductionSyncEngine
    public let clock: any Clock
    public let ids: any IDGenerator

    // ── Existing state
    public var currentProject: AudiobookProject?
    public var currentPackageRoot: URL?
    public var store: any ProductionStore
    public var recents: RecentsStore
    public var library: ProjectLibraryModel
    public var isTestEnvironment: Bool
    public var recoveryPackageRoot: URL?
    public var assets: (any ContentAddressedStore)?
    public var recoveryModel: AutosaveRecoveryModel?

    /// Reports which encoders this build can actually use (§16.3). Set by the
    /// app composition root (`StudioApp`), which is the only place allowed to
    /// name `VoxTranscoder` — the SwiftPM `VoxglassStudioKit` target cannot
    /// import the encoder target, and the diagnostics bundle (S12) needs the
    /// availability list without constructing an encoder itself.
    public var encoderAvailabilityProvider: () -> [String] = { [] }

    /// The one place entitlement is consulted for the app (§17.5). Only
    /// `Export*`/`Settings*` code and this file reference it (CI gate G-2).
    public let license: LicenseGate

    public var settings: SettingsModel

    /// Production sync coordinator (S10): publishes the projection to CloudKit and
    /// ingests review events. Live only when a project is open; harmless otherwise.
    public let projection: StudioProjectionCoordinator

    // ── Shell navigation (§18.1.1)
    public var selectedTab: ProjectTab = .dashboard
    public var presentedSheet: StudioSheet?
    /// Set when a library-side surface (Narration Needs) wants to take over the
    /// window; the library view renders it as a full-window surface.
    public var libraryMode: StudioLibraryMode = .library
    /// Callback the app shell installs to open a project window for a reference.
    public var onRequestProjectWindow: ((ProjectReference) -> Void)?
    /// Callback the app shell installs to close the current project window.
    public var onDismissProjectWindow: (() -> Void)?

    public var showAutosaveRecovery: Bool {
        recoveryModel != nil && recoveryPackageRoot != nil
    }

    public func presentRecoveryIfNeeded() {
        guard let root = recoveryPackageRoot, let project = currentProject else { return }
        let assetStore = assets ?? FileAssetStore(root: root)
        assets = assetStore
        recoveryModel = AutosaveRecoveryModel(
            packageRoot: root,
            store: store,
            assets: assetStore,
            project: project
        )
    }

    public func dismissRecovery() {
        recoveryModel = nil
        recoveryPackageRoot = nil
    }

    public init(
        capture: any AudioCapturing,
        metrics: any AudioMetricsCalculating,
        player: any SegmentPlayer,
        transcoder: any AudioTranscoding,
        sync: ProductionSyncEngine,
        clock: any Clock,
        ids: any IDGenerator,
        store: any ProductionStore = InMemoryProductionStore(),
        recents: RecentsStore = RecentsStore(),
        isTestEnvironment: Bool = false,
        seed: UITestSeed? = nil,
        licenseProvider: any LicenseProvider = StaticLicenseProvider(),
        encoderAvailability: @escaping () -> [String] = { [] }
    ) {
        self.capture = capture
        self.metrics = metrics
        self.player = player
        self.transcoder = transcoder
        self.sync = sync
        self.clock = clock
        self.ids = ids
        self.store = store
        self.recents = recents
        self.isTestEnvironment = isTestEnvironment
        self.license = LicenseGate(provider: licenseProvider)
        self.projection = StudioProjectionCoordinator(clock: clock)
        self.encoderAvailabilityProvider = encoderAvailability
        let library = ProjectLibraryModel(
            store: store,
            recents: recents,
            seed: seed,
            isTestEnvironment: isTestEnvironment
        )
        self.library = library
        self.settings = SettingsModel(gate: LicenseGate(provider: licenseProvider))
        library.onProjectOpened = { [weak self] project, openedStore in
            guard let self else { return }
            self.store = openedStore
            self.library.store = openedStore
            self.currentProject = project
            self.currentPackageRoot = self.library.pendingProjectURL
            self.rebuildPlayerIfNeeded()
            self.selectedTab = .dashboard
            self.presentedSheet = nil
            self.requestProjectWindow(for: project)
        }
        library.onAutosaveRecoveryAvailable = { [weak self] packageRoot in
            guard let self else { return }
            self.recoveryPackageRoot = packageRoot
        }
        library.onProjectAlreadyOpen = { [weak self] _ in
            // §8.3: focus the existing window (WindowGroup(for:) re-keys on the
            // same ProjectReference, so this is an openWindow call that
            // activates the already-open window).
            guard let self, let project = self.currentProject else { return }
            self.requestProjectWindow(for: project)
        }
    }

    // MARK: - Factories (§4.3)

    /// The live composition root. Called only from `StudioApp`, which can name
    /// the encoder (`VoxTranscoder`); the SwiftPM `VoxglassStudioKit` mirror
    /// cannot import the encoder target, so it never calls `.live`.
    public static func live(
        package: LivePackage = .none,
        transcoder: any AudioTranscoding,
        encoderAvailability: @escaping () -> [String]
    ) throws -> StudioEnvironment {
        let clock = SystemClock()
        let ids = UUIDGenerator()
        let recentsDir: URL? = package.recentsStorageDirectory
        let recents = RecentsStore(storageDirectory: recentsDir)
        let env = StudioEnvironment(
            capture: AVAudioEngineCapture(),
            metrics: AVMetricsCalculator(),
            player: AVSegmentPlayer(assets: FileAssetStore(root: FileManager.default.temporaryDirectory)),
            transcoder: transcoder,
            sync: ProductionSyncEngine(
                transport: CloudKitProductionSync(),
                state: DefaultsSyncStateStore()
            ),
            clock: clock,
            ids: ids,
            store: InMemoryProductionStore(),
            recents: recents,
            licenseProvider: StoreKitLicenseProvider(),
            encoderAvailability: encoderAvailability
        )
        if let url = package.url {
            env.initialPackageURL = url
        }
        return env
    }

    /// The seeded composition root (§19.6). Never touches the microphone,
    /// CloudKit, StoreKit, or the encoders; the fakes live in
    /// `Support/UITestFakes.swift` because gate G-9 forbids
    /// `VoxglassCoreTestSupport` in a shipping target (§19.2).
    public static func test(seed: UITestSeed) -> StudioEnvironment {
        #if DEBUG
        let clock = UITestFixedClock()
        let ids = UITestSequentialIDGenerator()
        let recents = RecentsStore(storageDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-ui-test-recents", isDirectory: true))
        return StudioEnvironment(
            capture: UITestAudioCapture(clock: clock, ids: ids),
            metrics: UITestMetricsCalculator(),
            player: UITestSegmentPlayer(),
            transcoder: UITestTranscoder(),
            sync: ProductionSyncEngine(transport: UITestSyncTransport(), state: UITestSyncStateStore()),
            clock: clock,
            ids: ids,
            store: InMemoryProductionStore(),
            recents: recents,
            isTestEnvironment: true,
            seed: seed,
            licenseProvider: UITestLicenseProvider()
        )
        #else
        // Release builds never seed (§19.6); `UITestSeed.init?(arguments:)`
        // returns nil there, so this branch is unreachable.
        fatalError("UITestSeed is unavailable in release builds")
        #endif
    }

    /// The package to open on launch, resolved by `.live(package:)`.
    public var initialPackageURL: URL?

    // MARK: - Navigation

    public func navigate(to route: StudioRoute) {
        apply(route)
    }

    public func push(to route: StudioRoute) {
        apply(route)
    }

    private func apply(_ route: StudioRoute) {
        switch route {
        case .dashboard: selectedTab = .dashboard; presentedSheet = nil
        case .script: selectedTab = .script; presentedSheet = nil
        case .record: selectedTab = .record; presentedSheet = nil
        case .review: selectedTab = .review; presentedSheet = nil
        case .assembly: selectedTab = .assemble; presentedSheet = nil
        case .metadata: selectedTab = .metadata; presentedSheet = nil
        case .validate: selectedTab = .validateExport; presentedSheet = nil
        case .sourceImport: presentedSheet = .sourceImport
        case .importAudio: presentedSheet = .importAudio
        case .export: presentedSheet = .export
        case .takeCompare: presentedSheet = .takeCompare
        case .devicePreview: presentedSheet = .devicePreview
        case .newProject: presentedSheet = .newProject
        case .needsBrowser: presentedSheet = .needsBrowser
        case .discovery: libraryMode = .discovery
        case .library, .settings:
            presentedSheet = nil
        }
    }

    public func popToRoot() {
        selectedTab = .dashboard
        presentedSheet = nil
    }

    /// Leaves the project window for the library; the project stays open in
    /// recents and can be reopened. Refreshes the cached snapshot and
    /// releases the advisory lock (§8.1, §8.3).
    public func closeProject() {
        let root = currentPackageRoot
        if let project = currentProject {
            Task { await library.refreshSummary(project: project, store: store) }
        }
        currentProject = nil
        currentPackageRoot = nil
        store = InMemoryProductionStore()
        presentedSheet = nil
        selectedTab = .dashboard
        library.releaseLock(for: root)
        onDismissProjectWindow?()
    }

    /// App termination / window teardown: release the advisory lock.
    public func releaseLock() {
        library.releaseLock(for: currentPackageRoot)
    }

    public func setProject(_ project: AudiobookProject) {
        currentProject = project
        store = library.store
        currentPackageRoot = library.pendingProjectURL
        rebuildPlayerIfNeeded()
        selectedTab = .dashboard
        presentedSheet = nil
        requestProjectWindow(for: project)
    }

    public func open(_ project: AudiobookProject, with openedStore: any ProductionStore) {
        store = openedStore
        library.store = openedStore
        currentProject = project
        currentPackageRoot = library.pendingProjectURL
        rebuildPlayerIfNeeded()
        selectedTab = .dashboard
        presentedSheet = nil
        requestProjectWindow(for: project)
    }

    /// Replace the in-memory project after an editor (e.g. Metadata & Rights)
    /// commits a change, without navigating away.
    public func updateProject(_ project: AudiobookProject) {
        currentProject = project
    }

    /// A fresh `FileAssetStore` rooted at the open package, or a temp dir when
    /// no package is open (tests).
    public func assetStoreForCurrentProject() -> any ContentAddressedStore {
        if let assets { return assets }
        if let root = currentPackageRoot {
            return FileAssetStore(root: root)
        }
        return FileAssetStore(root: FileManager.default.temporaryDirectory)
    }

    /// The package's `ArtworkStore` (cover-original + cover-2400 roles), or a
    /// temp store when no package is open.
    public func artworkStoreForCurrentProject() -> any ArtworkStore {
        if let root = currentPackageRoot {
            return FileArtworkStore(root: root)
        }
        return FileArtworkStore(root: FileManager.default.temporaryDirectory)
    }

    /// Kicks off a narration from a discovered need (n05/n06): a fresh
    /// public-domain project pre-filled from the need, routed to Source Import
    /// so short works and whole books share the multi-chapter toolset (§10).
    public func beginNarration(_ need: NarrationNeed) {
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: need.work.title, author: need.work.author, narrator: ""),
            rights: RightsEvidence(
                basis: .publicDomainUS,
                sourceURL: need.work.sourcePageURL,
                editionYear: need.provenance.editionYear,
                evidenceNotes: "Curated public-domain work surfaced by Narration Needs."
            ),
            profile: ProductionProfile(purpose: .publicDomainCommunity, intendedDestination: .librivox)
        )
        setProject(project)
        presentedSheet = .sourceImport
    }

    // MARK: - Project window plumbing

    public func requestProjectWindow(for project: AudiobookProject) {
        let bookmark: Data
        if let url = currentPackageRoot {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        } else {
            bookmark = Data()
        }
        onRequestProjectWindow?(ProjectReference(projectID: project.id, bookmark: bookmark))
    }

    private func rebuildPlayerIfNeeded() {
        player = AVSegmentPlayer(assets: assetStoreForCurrentProject())
    }
}

// MARK: - LivePackage

/// What `.live` should do about a package at launch (§4.3).
public enum LivePackage: Sendable {
    case none
    case temporary
    case url(URL)

    public static func temporary() -> LivePackage { .temporary }
    @MainActor
    public static func lastOpenedOrNone() -> LivePackage {
        let recents = RecentsStore()
        return recents.recentURLs.first.map { .url($0) } ?? .none
    }

    var url: URL? {
        if case .url(let u) = self { return u }
        return nil
    }

    var recentsStorageDirectory: URL? {
        if case .temporary = self {
            return FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-ui-test-recents", isDirectory: true)
        }
        return nil
    }
}

// MARK: - Shell vocabulary (§18.1.1)

public enum StudioSection: Hashable {
    case library, needsReview, readyToExport, archive, settings
}

public enum ProjectTab: Hashable, CaseIterable {
    case dashboard, script, record, review, assemble, metadata, validateExport

    public var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .script: "Script"
        case .record: "Record"
        case .review: "Review"
        case .assemble: "Assemble"
        case .metadata: "Metadata"
        case .validateExport: "Validate & Export"
        }
    }
}

public enum StudioSheet: Hashable {
    case newProject, needsBrowser
    case sourceImport, importAudio, export, takeCompare, devicePreview
}

public enum StudioLibraryMode: Hashable {
    case library
    case discovery
}

/// The value `WindowGroup(for:)` keys project windows on (spec §18.1.1):
/// the project UUID plus a security-scoped bookmark for window restoration.
public struct ProjectReference: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let bookmark: Data

    public init(projectID: UUID, bookmark: Data = Data()) {
        self.projectID = projectID
        self.bookmark = bookmark
    }

    public func resolveURL() -> URL? {
        guard !bookmark.isEmpty else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}

public enum StudioRoute: Sendable, Equatable, Hashable {
    case library
    case newProject
    case sourceImport
    case importAudio
    case takeCompare
    case dashboard
    case script
    case record
    case review
    case assembly
    case metadata
    case validate
    case export
    case devicePreview
    case settings
    case discovery
    case needsBrowser
}

public enum UITestSeed: String, Sendable, CaseIterable {
    case empty
    case onePreviewProject
    case watchQueue
    case oneFlaggedQueue
    case librivoxReady

    /// Reads the value after `-uiTestSeed` (§19.6). Returns `nil` on release
    /// builds regardless of arguments — seeding is DEBUG-only.
    public init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "-uiTestSeed"),
              index + 1 < arguments.count,
              let seed = UITestSeed(rawValue: arguments[index + 1]) else { return nil }
        #if DEBUG
        self = seed
        #else
        return nil
        #endif
    }
}
