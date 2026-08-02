import Foundation
import Observation
import VoxglassCore

// MARK: - ExportCard

/// The three destination cards in the Export wizard (§16.11 step 2).
/// The retail card is the single Pro-gated card; `DestinationProfile.tier`
/// decides. Cards are always visible; ineligible destinations show disabled
/// with their reason inline (§2.3, mockup `14-export-wizard`).
public enum ExportCard: String, Sendable, CaseIterable, Identifiable {
    case librivox
    case internetArchive
    case retail

    public var id: String { rawValue }

    public var profile: DestinationProfile {
        switch self {
        case .librivox: .librivox
        case .internetArchive: .internetArchive
        case .retail: .acx
        }
    }

    public var title: String {
        switch self {
        case .librivox: "LibriVox Contribution"
        case .internetArchive: "Internet Archive"
        case .retail: "Professional Retail Master"
        }
    }

    public var detail: String {
        switch self {
        case .librivox: "128 kbps CBR mono MP3 per section plus a submission checklist. Free, complete, and unlimited."
        case .internetArchive: "Lossless FLAC masters, optional MP3 derivatives, a metadata manifest, checksums, and a ready-to-paste ia upload command."
        case .retail: "Mastered chapter files, chapterized M4B, a retail sample, and an exportable validation report for ACX/Audible and Apple Books."
        }
    }

    public var isPro: Bool { profile.tier == .pro }

    /// The destination's primary codec (used to disable a card when the codec
    /// is unavailable on this build, §16.3.4).
    public var primaryCodec: Codec { profile.audio.codec }

    /// The feature gated when this card is chosen (the retail profile set).
    public var gatedFeature: ProFeature { .retailPresets }

    public var accessibilityIdentifier: String {
        "export.destination.\(rawValue)"
    }
}

// MARK: - ExportStep

public enum ExportStep: Int, Sendable {
    case scope = 1
    case destination = 2
    case confirm = 3
    case running = 4
    case done = 5
}

// MARK: - ExportModel

/// Backs the Export wizard (§16.11, §18.1.15).
///
/// Contract:
/// - Three steps: scope → destination → confirm & run, then a running and a
///   done state.
/// - The Pro gate is checked **exactly once**, at the step 2→3 transition,
///   via `LicenseGate.require(_:)` (§16.11). On `LicenseError.proRequired` the
///   model stops at step 2 and raises `showPurchase`; the purchase sheet's
///   success path calls `resumeAfterPurchase()`, which re-checks and proceeds
///   with **all selections preserved**.
/// - Free destinations (LibriVox, Internet Archive) never consult the gate —
///   the acceptance test proves this with a `FakeLicenseProvider` that fails on
///   any access.
@MainActor
@Observable
public final class ExportModel {
    // MARK: - State

    public private(set) var step: ExportStep = .scope

    /// Step 1 — scope.
    public var scope: ExportScope = .wholeBook
    public var selectedChapterIDs: Set<UUID> = []

    /// Step 2 — destination.
    public var card: ExportCard?
    public var retailProfile: DestinationID = .acx

    /// Step 3 — options.
    public var includeMP3Derivatives = false
    public var useTestCollection = false
    public var applyMastering = true
    public var m4bBitrateKbps = 128
    public var writeValidationReport = true
    public var overwriteExisting = true
    public var retailSampleRange: RetailSampleSelection?

    public private(set) var outputRoot: URL
    public private(set) var blockingIssues: [ValidationIssue] = []
    public private(set) var isRunning = false
    public private(set) var progress: ExportProgress?
    public private(set) var log: [String] = []
    public private(set) var completedBundle: ExportBundle?
    public private(set) var error: String?
    public var showPurchase = false

    public var blockingCount: Int { blockingIssues.count }
    public var canRun: Bool { card != nil && blockingIssues.isEmpty && !isRunning }

    /// The project being exported (value type; safe for the view to read).
    public let project: AudiobookProject

    /// Codecs this build can actually encode (§16.3.4 — the wizard disables a
    /// destination whose codec is unavailable instead of failing mid-export).
    public var availableEncoders: Set<Codec> { transcoder.availableEncoders }

    /// The narration-origin eligibility panel for the step-3 summary.
    public var eligibility: EligibilityProfile { EligibilityProfile.evaluate(project) }

    private var runTask: Task<Void, Never>?

    private let assets: any ContentAddressedStore
    private let renderer: any ChapterRenderable
    private let transcoder: any AudioTranscoding
    private let gate: LicenseGate
    private let now: @Sendable () -> Date

    public init(
        project: AudiobookProject,
        assets: any ContentAddressedStore,
        renderer: any ChapterRenderable,
        transcoder: any AudioTranscoding,
        gate: LicenseGate,
        outputRoot: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.project = project
        self.assets = assets
        self.renderer = renderer
        self.transcoder = transcoder
        self.gate = gate
        self.now = now
        self.outputRoot = outputRoot ?? Self.defaultOutputRoot(for: project)
    }

    // MARK: - Navigation

    /// Step 1 → 2, or step 2 → 3 (gate checked here). Returns whether the
    /// wizard is now on the confirm step.
    @discardableResult
    public func next() async -> Bool {
        switch step {
        case .scope:
            step = .destination
            return false
        case .destination:
            return await advanceToConfirm()
        case .confirm, .running, .done:
            return step == .confirm
        }
    }

    public func back() {
        switch step {
        case .destination: step = .scope
        case .confirm: step = .destination
        case .running: runTask?.cancel(); isRunning = false; step = .confirm
        default: break
        }
    }

    /// The single Pro-gate checkpoint (§16.11 step 2→3). Free destinations
    /// return without consulting the gate at all.
    public func advanceToConfirm() async -> Bool {
        guard let card else { return false }
        if card.isPro {
            do {
                try await gate.require(card.gatedFeature)
            } catch LicenseError.proRequired {
                showPurchase = true
                return false
            } catch {
                self.error = "Purchase check failed: \(error)"
                return false
            }
        }
        await refreshValidation()
        step = .confirm
        appendLog("Ready to export to \(card.title).")
        return true
    }

    /// Called after the purchase sheet succeeds. Re-checks the gate (now
    /// unlocked) and proceeds to step 3 with all selections intact.
    public func resumeAfterPurchase() async -> Bool {
        showPurchase = false
        return await advanceToConfirm()
    }

    /// Runs validation for the selected destination and fills the blocking
    /// issue list shown on step 3. Validation is free for every destination.
    public func refreshValidation() async {
        guard let card else { return }
        let profile = card.profile
        let settings = project.profile.assembly
        let eligibility = EligibilityProfile.evaluate(project)
        var metrics: [UUID: AudioQualityMetrics] = [:]
        for paragraph in project.allParagraphs {
            guard let selectedID = paragraph.selectedTakeID,
                  let take = paragraph.takes.first(where: { $0.id == selectedID }),
                  let takeMetrics = take.metrics else { continue }
            metrics[take.id] = takeMetrics
        }
        let issues = ValidationRuleEngine().evaluate(
            project: project,
            metrics: metrics,
            profile: profile,
            eligibility: eligibility,
            assembly: settings
        )
        blockingIssues = issues.filter { $0.severity == .blocking }
    }

    // MARK: - Run

    /// Starts the export on a tracked task so it can be cancelled.
    public func run() {
        guard !isRunning, let card else { return }
        isRunning = true
        step = .running
        error = nil
        progress = nil
        log.removeAll()
        appendLog("Starting export to \(card.title)…")
        runTask = Task { [weak self] in
            await self?.performRun()
        }
    }

    public func cancel() {
        runTask?.cancel()
    }

    /// Runs the export and awaits completion — the deterministic entry point
    /// for tests; the view uses `run()` and observes `step`/`progress`.
    public func runAndWait() async {
        run()
        await runTask?.value
    }

    /// The cancellable export body. Runs the selected destination's package
    /// builder against the real renderer/transcoder/asset store and records
    /// per-file progress.
    func performRun() async {
        defer { isRunning = false }
        guard let card else { return }

        let builder: any PackageBuilder = {
            switch card {
            case .librivox: LibriVoxPackageBuilder()
            case .internetArchive: InternetArchivePackageBuilder()
            case .retail: RetailMasterPackageBuilder(destination: retailProfile)
            }
        }()

        let options = ExportOptions(
            includeMP3Derivatives: includeMP3Derivatives,
            useTestCollection: useTestCollection,
            applyMastering: applyMastering,
            m4bBitrateKbps: m4bBitrateKbps,
            retailSample: retailSampleRange,
            overwriteExisting: overwriteExisting,
            writeValidationReport: writeValidationReport,
            scope: scope,
            generatedAt: now(),
            appVersion: Self.appVersion
        )

        do {
            let bundle = try await builder.build(
                project: project,
                renders: renderer,
                transcoder: transcoder,
                assets: assets,
                into: outputRoot,
                options: options,
                progress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.progress = update
                    }
                }
            )
            completedBundle = bundle
            progress = ExportProgress(
                phase: .done,
                completedUnits: bundle.files.count,
                totalUnits: bundle.files.count,
                fractionCompleted: 1
            )
            appendLog("Exported \(bundle.files.count) files (\(PackagingSupport.clockTime(bundle.totalDuration))) to \(bundle.rootURL.path)")
            step = .done
        } catch is CancellationError {
            appendLog("Export cancelled.")
            step = .confirm
        } catch let error as PackagingError {
            self.error = Self.describe(error)
            appendLog("Export failed: \(Self.describe(error))")
            step = .confirm
        } catch {
            self.error = error.localizedDescription
            appendLog("Export failed: \(error.localizedDescription)")
            step = .confirm
        }
    }

    // MARK: - Helpers

    private func appendLog(_ line: String) {
        log.append("[\(Self.timeStamp(self.now()))] \(line)")
    }

    private static func timeStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func describe(_ error: PackagingError) -> String {
        switch error {
        case .ineligible(let destination, let reason):
            return "\(destination.rawValue) is not eligible: \(reason)"
        case .blockingIssues(let issues):
            return "\(issues.count) blocking issue(s) must be fixed before exporting."
        case .encoderUnavailable(let codec):
            return "The \(codec) encoder could not be loaded, so this export is unavailable. Reinstall Voxglass Studio."
        case .projectNotReady(let reason):
            return reason
        }
    }

    private static func defaultOutputRoot(for project: AudiobookProject) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let slug = PackagingSupport.directorySlug(project.metadata.title)
        return base
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version {
            return build.map { "Voxglass Studio \(version) (\($0))" } ?? "Voxglass Studio \(version)"
        }
        return "Voxglass Studio 1.0"
    }
}
