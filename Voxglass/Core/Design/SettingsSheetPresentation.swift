import Foundation

/// Semantic contract for the Listen gear → Settings sheet. iOS owns dismissal
/// (drag / standard gesture); the app injects no Close button.
struct SettingsSheetPresentation: Equatable, Sendable {
    let title: String
    let showsAppDismissButton: Bool
    let showsDragIndicator: Bool

    static let listenEntry = SettingsSheetPresentation(
        title: "Settings",
        showsAppDismissButton: false,
        showsDragIndicator: true
    )
}
