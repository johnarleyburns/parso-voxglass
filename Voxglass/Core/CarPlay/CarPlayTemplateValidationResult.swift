import Foundation

/// The value returned by the CarPlay tab validation boundary before UIKit
/// templates are constructed. Keeping this value in the core target makes the
/// decision observable in host tests and keeps framework construction separate
/// from normalization.
public struct CarPlayTemplateValidationResult<T: Equatable & Sendable>: Equatable, Sendable {
    public let normalizedTabs: [T]
    public let droppedIDs: [String]
    public let diagnosticReason: String?

    public init(
        normalizedTabs: [T],
        droppedIDs: [String] = [],
        diagnosticReason: String? = nil
    ) {
        self.normalizedTabs = normalizedTabs
        self.droppedIDs = droppedIDs
        self.diagnosticReason = diagnosticReason
    }

    public var requiresFallback: Bool {
        normalizedTabs.isEmpty
    }
}
