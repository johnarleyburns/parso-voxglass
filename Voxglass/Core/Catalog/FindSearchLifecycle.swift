import Foundation

/// Separates the Find text field's draft from the query the user actually
/// submitted, so empty-result messaging is only shown for a submitted search.
public struct FindSearchLifecycle: Equatable, Sendable {
    public enum EmptyState: Equatable, Sendable {
        case instructional
        case noBooks
        case noResults
    }

    public private(set) var submittedQuery: String = ""
    public private(set) var hasSubmittedSearch = false

    public init() {}

    public static func normalized(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Records a submission; returns the normalized term, or nil when empty.
    @discardableResult
    public mutating func submit(draft: String) -> String? {
        let term = Self.normalized(draft)
        guard !term.isEmpty else { return nil }
        submittedQuery = term
        hasSubmittedSearch = true
        return term
    }

    public mutating func reset() {
        submittedQuery = ""
        hasSubmittedSearch = false
    }

    /// True when the draft still matches the submitted query.
    public func isCurrent(draft: String) -> Bool {
        let term = Self.normalized(draft)
        return hasSubmittedSearch && !term.isEmpty && term == submittedQuery
    }

    /// Content for an empty, idle result area.
    public func emptyState(draft: String) -> EmptyState {
        if Self.normalized(draft).isEmpty { return .noBooks }
        return isCurrent(draft: draft) ? .noResults : .instructional
    }

    /// Whether the result surface (rather than the instructional panel) shows.
    public func showsResultsSurface(
        draft: String,
        hasSelectedCollection: Bool,
        isSearching: Bool,
        hasResults: Bool
    ) -> Bool {
        isCurrent(draft: draft) || hasSelectedCollection || isSearching || hasResults
    }
}
