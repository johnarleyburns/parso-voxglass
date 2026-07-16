import Foundation

/// Tracks which player items currently hold a live EQ processing tap, keyed by
/// object identity. Extracted so the "one tap per item" bookkeeping — the fix for
/// EQ silently dying on every gapless auto-advance — is unit-testable with no
/// AVFoundation: one processor structurally cannot serve two items through a
/// single tap, so each item gets its own, and item-changed evicts the old one.
public final class EQTapRegistry {
    public private(set) var identifiers: Set<ObjectIdentifier> = []

    public var count: Int { identifiers.count }
    public var isEmpty: Bool { identifiers.isEmpty }

    public func isAttached(_ object: AnyObject) -> Bool {
        identifiers.contains(ObjectIdentifier(object))
    }

    /// Records a tap for `object`. Returns `true` when newly attached (was absent).
    @discardableResult
    public func attach(_ object: AnyObject) -> Bool {
        identifiers.insert(ObjectIdentifier(object)).inserted
    }

    /// Evicts the tap for `object`. Returns `true` when something was removed.
    @discardableResult
    public func evict(_ object: AnyObject) -> Bool {
        identifiers.remove(ObjectIdentifier(object)) != nil
    }

    public func evict(identifier: ObjectIdentifier) {
        identifiers.remove(identifier)
    }

    public func evictAll() {
        identifiers.removeAll()
    }
}
