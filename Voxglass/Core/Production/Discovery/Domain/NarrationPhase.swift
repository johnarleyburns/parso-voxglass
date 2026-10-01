import Foundation

/// The user-facing phase of a narration project.
public enum NarrationPhase: Equatable, Sendable {
    case draft
    case recording(recorded: Int, total: Int)
    case review(pending: Int, total: Int)
    case package
    case ready

    /// Derives a phase from the existing project counts and export state.
    public init(recorded: Int, approved: Int, total: Int, hasExport: Bool) {
        let total = max(total, 0)
        if hasExport && total > 0 && approved >= total {
            self = .ready
        } else if total > 0 && approved >= total {
            self = .package
        } else if recorded >= total && total > 0 {
            self = .review(pending: max(total - approved, 0), total: total)
        } else if recorded > 0 {
            self = .recording(recorded: min(recorded, total), total: total)
        } else {
            self = .draft
        }
    }

    public var label: String {
        switch self {
        case .draft: String(localized: "Draft", bundle: .module)
        case .recording: String(localized: "Recording", bundle: .module)
        case .review: String(localized: "Review", bundle: .module)
        case .package: String(localized: "Package", bundle: .module)
        case .ready: String(localized: "Ready", bundle: .module)
        }
    }

    public var caption: String {
        switch self {
        case .draft: String(localized: "Rights and disclaimer ready", bundle: .module)
        case let .recording(recorded, total): String(localized: "\(recorded) of \(total) paragraphs recorded", bundle: .module)
        case let .review(pending, _): String(localized: "\(pending) takes to review", bundle: .module)
        case .package: String(localized: "Approved, ready to package", bundle: .module)
        case .ready: String(localized: "Package ready to hand off", bundle: .module)
        }
    }
}
