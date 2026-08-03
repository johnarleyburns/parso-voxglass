import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VoxglassCore

/// The Studio's app-level preferences (§18.1.16). Recording defaults apply to
/// *new* projects; per-project `RecordingDefaults` (S5) continue to win while a
/// project is open. Everything is persisted to `UserDefaults` under one key.
public struct StudioSettings: Codable, Sendable, Equatable {
    // Audio
    public var inputDeviceUID: String = "" // "" = system default
    public var recordingSampleRate: Double = 48_000
    public var recordingBitDepth: Int = 24
    public var monitoringEnabled: Bool = false
    public var preRollSeconds: TimeInterval = 1.0
    public var warnOnClipping: Bool = true
    public var autoComputeMetrics: Bool = true

    // Recording
    public var autoSelectNewestTake: Bool = true
    public var skipRecordedOnAdvance: Bool = false
    public var autoAdvance: Bool = true
    public var teleprompterSize: Double = 24

    // Preview Sync
    public var proxyBitrateKbps: Int = 80
    public var autoSyncDefault: Bool = true

    public init() {}
}

// MARK: - SettingsModel

/// Backs the Settings window (§18.1.16, mockup `15-settings-audio`), five tabs.
/// This is one of the two places a purchase is reachable (the other is the
/// Export wizard's retail card, §2.4), so the model may consult the license
/// gate (CI gate G-2 allows `Settings*` files).
@MainActor
@Observable
public final class SettingsModel {
    public enum Tab: String, Sendable, CaseIterable, Identifiable {
        case audio, recording, previewSync, storage, license
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .audio: "Audio"
            case .recording: "Recording"
            case .previewSync: "Preview Sync"
            case .storage: "Storage"
            case .license: "License"
            }
        }
        public var accessibilityIdentifier: String { "settings.tab.\(rawValue)" }
    }

    public var tab: Tab = .audio

    public var settings: StudioSettings {
        didSet { persist() }
    }

    // License tab
    public private(set) var entitlement: EntitlementState = .free
    public private(set) var productInfo: ProductInfo?
    public private(set) var isWorking = false
    public private(set) var message: String?

    public var isPro: Bool {
        if case .pro = entitlement { return true }
        return false
    }

    // Storage tab
    public private(set) var storageReport: StorageReport?
    public private(set) var integritySummary: String?

    public let gate: LicenseGate

    private let defaults: UserDefaults
    private let settingsKey = "voxglass.studio.settings"

    public init(
        gate: LicenseGate,
        defaults: UserDefaults = .standard
    ) {
        self.gate = gate
        self.defaults = defaults
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(StudioSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = StudioSettings()
        }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    // MARK: - License

    public func refreshEntitlement() async {
        entitlement = await gate.provider.entitlement
    }

    public func loadProduct() async {
        guard productInfo == nil else { return }
        productInfo = try? await gate.provider.product()
    }

    public func purchase() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await gate.provider.purchasePro()
            entitlement = state
            message = {
                if case .pro = state { return "Voxglass Studio Pro is unlocked." }
                return nil
            }()
        } catch LicenseError.cancelled {
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    public func restore() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let state = try await gate.provider.restore()
            entitlement = state
            message = {
                if case .pro = state { return "Purchase restored." }
                return "No previous purchase was found for this Apple ID."
            }()
        } catch {
            message = error.localizedDescription
        }
    }

    public func dismissMessage() {
        message = nil
    }

    /// Clears both the transient message and a verification summary (used by
    /// the Project window's Verify Project command).
    public func dismissVerification() {
        message = nil
        integritySummary = nil
    }

    /// Surface a transient message from the view (informational buttons).
    public func setMessage(_ text: String?) {
        message = text
    }

    // MARK: - Storage

    public func computeStorageReport(packageRoot: URL?, project: AudiobookProject?) async {
        guard let packageRoot, let project else {
            storageReport = nil
            return
        }
        do {
            let package = try await ProjectPackage.open(packageRoot)
            storageReport = try await StorageAnalyzer().report(package: package, project: project)
        } catch {
            storageReport = nil
        }
    }

    public func verifyProject(assets: (any ContentAddressedStore)?, project: AudiobookProject?) async {
        guard let assets, let project else { return }
        let findings = ProjectIntegrity.check(project, assets: assets, deep: false)
        integritySummary = findings.isEmpty
            ? "No integrity issues found."
            : "\(findings.count) integrity issue(s) found."
    }

    public func copyDiagnostics(packageRoot: URL?) {
        let lines = [
            "Voxglass Studio diagnostics",
            "Package: \(packageRoot?.path ?? "none open")",
            "Entitlement: \(String(describing: entitlement))",
            "Storage: \(storageReport.map { "\($0.originalBytes) original bytes" } ?? "unavailable")"
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        message = "Diagnostics copied to the clipboard."
    }

    /// S12 (§4.6, §21.5): writes the diagnostics bundle (zip) to a user-chosen
    /// location. Contains integrity findings, schema version, entitlement,
    /// encoder availability, devices, storage, and the log tail — never audio
    /// or manuscript text.
    public func exportDiagnosticsBundle(
        packageRoot: URL?,
        project: AudiobookProject?,
        assets: (any ContentAddressedStore)?,
        encoderAvailability: [String]
    ) async {
        isWorking = true
        defer { isWorking = false }

        var content = DiagnosticsBundleContent(
            appVersion: ProcessInfo.processInfo.operatingSystemVersionString.isEmpty
                ? "Voxglass Studio"
                : "Voxglass Studio (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))",
            entitlement: entitlementLabel(for: entitlement)
        )
        content.logTail = DiagnosticsBundleWriter.logTail()
        content.encoderAvailability = encoderAvailability
        if let packageRoot {
            content.schemaVersion = (try? ProjectPackage.readManifest(packageRoot).schemaVersion) ?? 0
        }
        if let report = storageReport {
            content.storageReport = "Storage report\n\(ByteCountFormatter.string(fromByteCount: report.originalBytes, countStyle: .file)) originals\n\(ByteCountFormatter.string(fromByteCount: report.renderBytes, countStyle: .file)) renders\n\(ByteCountFormatter.string(fromByteCount: report.proxyBytes, countStyle: .file)) proxies\n\(ByteCountFormatter.string(fromByteCount: report.exportBytes, countStyle: .file)) exports\n"
        }
        if let project, let assets {
            let findings = ProjectIntegrity.check(project, assets: assets, deep: false)
            content.integrityFindings = findings.map { finding in
                "\(finding.severity.rawValue): \(finding.code.rawValue) — \(finding.message)"
            }
        }

        guard let directory = diagnosticsDestinationDirectory() else { return }

        do {
            let zipURL = try DiagnosticsBundleWriter.writeZip(
                content.renderedFiles(),
                into: directory.appendingPathComponent("voxglass-diagnostics", isDirectory: true),
                outputURL: directory.appendingPathComponent("voxglass-diagnostics.zip")
            )
            NSWorkspace.shared.activateFileViewerSelecting([zipURL])
            message = "Diagnostics bundle written to \(zipURL.lastPathComponent)."
        } catch {
            message = "Could not write the diagnostics bundle: \(error.localizedDescription)"
        }
    }

    private func entitlementLabel(for state: EntitlementState) -> String {
        switch state {
        case .pro: "pro (unlocked)"
        case .free: "free"
        case .pending: "pending"
        case .unknown: "verifying"
        }
    }

    private func diagnosticsDestinationDirectory() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voxglass-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.deletingLastPathComponent()
    }

    // MARK: - Audio devices

    /// AVAudioDevice enumeration is SDK-version-dependent; expose a stable
    /// UID field for now so recordings can pin a specific input by UID.
    public static let defaultInputDeviceUID = ""
}
