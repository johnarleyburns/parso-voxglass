import Foundation

// MARK: - ProFeature

/// The discrete capabilities gated behind the one-time Pro purchase (§2.2).
///
/// Every case maps to the same entitlement in MVP; the enum exists so the
/// *call sites* are self-documenting and a future tier split is mechanical
/// (§17.3).
public enum ProFeature: String, Codable, Sendable, CaseIterable {
    /// Retail destination profiles in the Export wizard (ACX, Apple Books…).
    case retailPresets
    /// The documented mastering chain (§16.7).
    case mastering
    /// Chapterized M4B with embedded chapters (§3.4.4).
    case m4bExport
    /// FLAC masters.
    case flacExport
    /// Unattended whole-book batch export with resume.
    case batchExport
    /// Commercial-only metadata fields and the retail sample.
    case commercialMetadata
    /// Writing the validation report to disk (JSON/HTML).
    case validationReportExport

    public var displayName: String {
        switch self {
        case .retailPresets: "Retail destination profiles"
        case .mastering: "Mastering chain"
        case .m4bExport: "Chapterized M4B"
        case .flacExport: "FLAC masters"
        case .batchExport: "Batch export"
        case .commercialMetadata: "Commercial metadata"
        case .validationReportExport: "Exportable validation reports"
        }
    }
}

// MARK: - Narration Pro product identity

/// The single source of the "Voxglass Narration Pro" product identity (§2.2).
///
/// Both strings are read from here, never inlined at a call site. The price is
/// deliberately not a constant — it lives in App Store Connect and is set at
/// submission (decision D-2).
public enum NarrationProProduct {
    /// The App Store Connect product id of the one-time Pro purchase.
    public static let productID = "guru.parso.voxglass.narration.pro"
    /// The display name shown in every purchase surface.
    public static let displayName = "Voxglass Narration Pro"
}

// MARK: - EntitlementState

/// The current license state as seen by the UI and the gate (§17.2).
public enum EntitlementState: Sendable, Equatable {
    case free
    case pro(since: Date)
    /// An in-progress purchase (Ask to Buy / approval pending).
    case pending
    /// StoreKit could not verify the entitlement — never treated as Pro.
    case unknown
}

// MARK: - ProductInfo

/// Localized product presentation data for the purchase UI (§17.2).
public struct ProductInfo: Sendable, Equatable {
    public var displayPrice: String
    public var displayName: String
    public var description: String

    public init(displayPrice: String, displayName: String, description: String) {
        self.displayPrice = displayPrice
        self.displayName = displayName
        self.description = description
    }
}

// MARK: - LicenseError

public enum LicenseError: Error, Sendable, Equatable {
    /// The feature is not unlocked; carries the feature that was requested.
    case proRequired(ProFeature)
    /// The user cancelled the StoreKit purchase sheet.
    case cancelled
    /// The product is not configured for this build/store.
    case notAvailable
    /// A StoreKit/purchase failure with a human-readable reason.
    case purchaseFailed(String)
    /// The verification result could not be trusted.
    case unverified
}

// MARK: - LicenseProvider

/// The entitlement seam (§17.2). StoreKit is the production implementation;
/// tests use `FakeLicenseProvider` (§19.2). Nothing in this file knows about
/// StoreKit, so the Core target stays dependency-free.
public protocol LicenseProvider: Sendable {
    var entitlement: EntitlementState { get async }
    var updates: AsyncStream<EntitlementState> { get }
    func refresh() async
    func purchasePro() async throws -> EntitlementState
    func restore() async throws -> EntitlementState
    func product() async throws -> ProductInfo
}

// MARK: - LicenseGate

/// The single type that may consult entitlement (§2.3, §17.3).
///
/// CI gate G-2 enforces that `LicenseGate` / `ProFeature` / `EntitlementState`
/// are referenced only from `Export*`, `Packaging/**`, `RetailMaster*`,
/// `Master*`, `License*`, `Settings*`, and `StudioEnvironment.swift` — so
/// recording, review, sync, assembly, and preview code can never gate a free
/// workflow.
public struct LicenseGate: Sendable {
    public let provider: any LicenseProvider

    public init(provider: any LicenseProvider) {
        self.provider = provider
    }

    public func require(_ feature: ProFeature) async throws {
        guard await isUnlocked(feature) else {
            throw LicenseError.proRequired(feature)
        }
    }

    public func isUnlocked(_ feature: ProFeature) async -> Bool {
        switch await provider.entitlement {
        case .pro: return true
        case .free, .pending, .unknown: return false
        }
    }
}

// MARK: - StaticLicenseProvider

/// A provider pinned to one fixed entitlement. Used as the boot-time default
/// before a StoreKit provider confirms (§17.4) and as scaffolding in DEBUG
/// builds. Never consulted by the free export path.
public struct StaticLicenseProvider: LicenseProvider {
    public let fixed: EntitlementState
    public let productInfo: ProductInfo
    private let stream: AsyncStream<EntitlementState>

    public init(
        entitlement: EntitlementState = .free,
        productInfo: ProductInfo = ProductInfo(
            // The price is deliberately not in code (§2.2, D-2): it lives in App
            // Store Connect and is read back by `StoreKitLicenseProvider.product()`.
            // This scaffold leaves the field empty so a real value is never invented.
            displayPrice: "",
            displayName: NarrationProProduct.displayName,
            description: "Unlock professional retail delivery: mastered MP3/WAV/FLAC chapter files, chapterized M4B, retail samples, batch export, and exportable validation reports. One-time purchase, no subscription."
        )
    ) {
        self.fixed = entitlement
        self.productInfo = productInfo
        self.stream = AsyncStream { $0.finish() }
    }

    public var entitlement: EntitlementState {
        get async { fixed }
    }

    public var updates: AsyncStream<EntitlementState> { stream }

    public func refresh() async {}

    public func purchasePro() async throws -> EntitlementState { fixed }

    public func restore() async throws -> EntitlementState { fixed }

    public func product() async throws -> ProductInfo { productInfo }
}
