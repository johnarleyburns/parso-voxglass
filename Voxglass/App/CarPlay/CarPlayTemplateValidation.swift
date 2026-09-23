import CarPlay
import OSLog
import UIKit
import VoxglassCore

/// The framework validates a tab bar synchronously and can terminate the app
/// for an invalid template set. Both CarPlay surfaces pass through this
/// boundary before constructing `CPTabBarTemplate`.
@MainActor
enum CarPlayTemplateValidation {
    /// The available tab count is entitlement-dependent. Audio apps commonly
    /// receive fewer slots than the five tabs in our value model, and
    /// CPTabBarTemplate throws an Objective-C exception when given too many
    /// root templates. Always ask CarPlay for the runtime limit immediately
    /// before constructing the tab bar.
    static var maximumTabCount: Int {
        max(0, min(5, CPTabBarTemplate.maximumTabCount))
    }
    static let maximumSectionCount = 12
    static let maximumItemsPerSection = 12
    private static let fallbackSystemImage = "rectangle.stack.fill"
    private static let logger = Logger(subsystem: "guru.parso.voxglass", category: "CarPlay")

    static func consumerResult(_ tabs: [CarPlayTab]) -> CarPlayTemplateValidationResult<CarPlayTab> {
        var seen = Set<CarPlayTabID>()
        var droppedIDs: [String] = []
        let valid = tabs.compactMap { tab -> CarPlayTab? in
            guard !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                droppedIDs.append(tab.id.rawValue)
                logger.error("rejectedConsumerTab reason=missingTitle id=\(tab.id.rawValue, privacy: .public)")
                return nil
            }
            guard seen.insert(tab.id).inserted else {
                droppedIDs.append(tab.id.rawValue)
                logger.error("rejectedConsumerTab reason=duplicateID id=\(tab.id.rawValue, privacy: .public)")
                return nil
            }
            var normalized = tab
            normalized.systemImage = validSystemImage(tab.systemImage)
            normalized.sections = normalizedSections(tab.sections)
            return normalized
        }
        let normalized = Array(valid.prefix(maximumTabCount))
        droppedIDs.append(contentsOf: valid.dropFirst(maximumTabCount).map { $0.id.rawValue })
        let diagnosticReason: String?
        if normalized.isEmpty {
            diagnosticReason = tabs.isEmpty ? "emptyInput" : "noRepresentableTabs"
        } else if valid.count > maximumTabCount {
            diagnosticReason = "tabLimitExceeded"
        } else {
            diagnosticReason = nil
        }
        logger.info("consumerTabsValidated count=\(normalized.count, privacy: .public) ids=\(normalized.map { $0.id.rawValue }.joined(separator: ","), privacy: .public) dropped=\(droppedIDs.joined(separator: ","), privacy: .public) reason=\(diagnosticReason ?? "none", privacy: .public)")
        return CarPlayTemplateValidationResult(
            normalizedTabs: normalized,
            droppedIDs: droppedIDs,
            diagnosticReason: diagnosticReason
        )
    }

    static func productionResult(_ tabs: [ProductionCarPlayTab]) -> CarPlayTemplateValidationResult<ProductionCarPlayTab> {
        var seen = Set<String>()
        var droppedIDs: [String] = []
        let valid = tabs.compactMap { tab -> ProductionCarPlayTab? in
            guard !tab.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                droppedIDs.append(tab.id)
                logger.error("rejectedProductionTab reason=missingIDOrTitle id=\(tab.id, privacy: .public)")
                return nil
            }
            guard seen.insert(tab.id).inserted else {
                droppedIDs.append(tab.id)
                logger.error("rejectedProductionTab reason=duplicateID id=\(tab.id, privacy: .public)")
                return nil
            }
            var normalized = tab
            normalized.systemImage = validSystemImage(tab.systemImage)
            normalized.sections = normalizedProductionSections(tab.sections)
            return normalized
        }
        let normalized = Array(valid.prefix(maximumTabCount))
        droppedIDs.append(contentsOf: valid.dropFirst(maximumTabCount).map(\.id))
        let diagnosticReason: String?
        if normalized.isEmpty {
            diagnosticReason = tabs.isEmpty ? "emptyInput" : "noRepresentableTabs"
        } else if valid.count > maximumTabCount {
            diagnosticReason = "tabLimitExceeded"
        } else {
            diagnosticReason = nil
        }
        logger.info("productionTabsValidated count=\(normalized.count, privacy: .public) ids=\(normalized.map(\.id).joined(separator: ","), privacy: .public) dropped=\(droppedIDs.joined(separator: ","), privacy: .public) reason=\(diagnosticReason ?? "none", privacy: .public)")
        return CarPlayTemplateValidationResult(
            normalizedTabs: normalized,
            droppedIDs: droppedIDs,
            diagnosticReason: diagnosticReason
        )
    }

    private static func validSystemImage(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && UIImage(systemName: trimmed) != nil ? trimmed : fallbackSystemImage
    }

    private static func normalizedSections(_ sections: [CarPlaySection]) -> [CarPlaySection] {
        sections.prefix(maximumSectionCount).map { section in
            var normalized = section
            normalized.items = Array(section.items.prefix(maximumItemsPerSection))
            return normalized
        }
    }

    private static func normalizedProductionSections(_ sections: [ProductionCarPlaySection]) -> [ProductionCarPlaySection] {
        sections.prefix(maximumSectionCount).map { section in
            var normalized = section
            normalized.items = Array(section.items.prefix(maximumItemsPerSection))
            return normalized
        }
    }

}
