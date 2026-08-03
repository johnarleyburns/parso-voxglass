import Foundation
import VoxglassCore
import Observation

@MainActor
@Observable
public final class StudioEnvironment {
    public var navigationPath: [StudioRoute] = []
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
        store: any ProductionStore = InMemoryProductionStore(),
        recents: RecentsStore = RecentsStore(),
        isTestEnvironment: Bool = false,
        seed: UITestSeed? = nil,
        licenseProvider: any LicenseProvider = StaticLicenseProvider()
    ) {
        self.store = store
        self.recents = recents
        self.isTestEnvironment = isTestEnvironment
        self.license = LicenseGate(provider: licenseProvider)
        self.projection = StudioProjectionCoordinator()
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
            self.navigationPath = [.dashboard]
        }
        library.onAutosaveRecoveryAvailable = { [weak self] packageRoot in
            guard let self else { return }
            self.recoveryPackageRoot = packageRoot
        }
    }

    public func navigate(to route: StudioRoute) {
        navigationPath = [route]
    }

    public func push(to route: StudioRoute) {
        navigationPath.append(route)
    }

    public func popToRoot() {
        navigationPath.removeAll()
    }

    public func setProject(_ project: AudiobookProject) {
        currentProject = project
        navigationPath = [.dashboard]
    }

    public func open(_ project: AudiobookProject, with openedStore: any ProductionStore) {
        store = openedStore
        library.store = openedStore
        currentProject = project
        navigationPath = [.dashboard]
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
}

public enum StudioRoute: Sendable, Equatable, Hashable {
    case library
    case newProject
    case sourceImport
    case importAudio
    case takeCompare
    case dashboard
    case record
    case review
    case assembly
    case metadata
    case validate
    case export
    case devicePreview
    case settings
}

public enum UITestSeed: String, Sendable, CaseIterable {
    case empty
    case onePreviewProject
    case watchQueue
    case oneFlaggedQueue
    case librivoxReady
}
