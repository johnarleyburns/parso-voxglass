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
        case .draft: "Draft"
        case .recording: "Recording"
        case .review: "Review"
        case .package: "Package"
        case .ready: "Ready"
        }
    }

    public var caption: String {
        switch self {
        case .draft: "Rights and disclaimer ready"
        case let .recording(recorded, total): "\(recorded) of \(total) paragraphs recorded"
        case let .review(pending, _): "\(pending) takes to review"
        case .package: "Approved, ready to package"
        case .ready: "Package ready to hand off"
        }
    }
}
