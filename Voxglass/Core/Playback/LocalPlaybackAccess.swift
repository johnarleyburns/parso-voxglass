import Foundation
import os

/// The start/stop pair behind security-scoped file access. Abstracted so the
/// lease registry can be exercised in host tests without real picker grants.
public protocol SecurityScopedAccessing: Sendable {
    /// Returns false when the scope could not be acquired.
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemSecurityScopedAccess: SecurityScopedAccessing {
    public init() {}
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// One acquisition of access to a security-scoped URL. Exactly one `release()`
/// (explicit or via `deinit`) pairs with the acquire that created it, so a
/// dropped lease can never leak a scope.
public final class PlaybackLease: Sendable {
    public let url: URL
    private let registry: SecurityScopedLeaseRegistry
    private let released = OSAllocatedUnfairLock<Bool>(initialState: false)

    fileprivate init(url: URL, registry: SecurityScopedLeaseRegistry) {
        self.url = url
        self.registry = registry
    }

    public func release() {
        let shouldRelease = released.withLock { state -> Bool in
            guard !state else { return false }
            state = true
            return true
        }
        if shouldRelease { registry.releaseOne(url) }
    }

    deinit { release() }
}

/// Reference-counted security-scoped access. The scope is started when the
/// first lease for a URL is acquired and stopped when the last one is
/// released, so sharing a URL between the current and preloaded item is safe.
/// Only URLs with live leases are tracked; the table is empty when idle.
public final class SecurityScopedLeaseRegistry: Sendable {
    public static let shared = SecurityScopedLeaseRegistry()

    private let access: any SecurityScopedAccessing
    private let counts = OSAllocatedUnfairLock<[URL: Int]>(initialState: [:])

    public init(access: any SecurityScopedAccessing = SystemSecurityScopedAccess()) {
        self.access = access
    }

    /// Number of live leases across all URLs.
    public var activeLeaseCount: Int { counts.withLock { $0.values.reduce(0, +) } }

    /// Nil when the system denies the scope.
    public func acquire(_ url: URL) -> PlaybackLease? {
        let granted = counts.withLock { table -> Bool in
            if let count = table[url] {
                table[url] = count + 1
                return true
            }
            guard access.startAccessing(url) else { return false }
            table[url] = 1
            return true
        }
        return granted ? PlaybackLease(url: url, registry: self) : nil
    }

    fileprivate func releaseOne(_ url: URL) {
        counts.withLock { table in
            guard let count = table[url] else { return }
            if count <= 1 {
                table.removeValue(forKey: url)
                access.stopAccessing(url)
            } else {
                table[url] = count - 1
            }
        }
    }
}

/// Typed result of resolving a chapter's audio source. A local-only failure
/// never carries a URL and never falls back to a remote that doesn't exist.
public enum PlaybackSourceResolution: Sendable {
    /// A readable local file; `lease` is non-nil when it needed a security scope.
    case playableLocal(URL, lease: PlaybackLease?)
    case remoteFallback(URL)
    case staleBookmark
    case scopeDenied
    case missingFile
    case unreadableFile

    public var isFailure: Bool {
        switch self {
        case .playableLocal, .remoteFallback: false
        default: true
        }
    }
}

public struct PlaybackSourceResolver: Sendable {
    public typealias BookmarkResolver = @Sendable (Data) -> (url: URL, isStale: Bool)?

    public static let system = PlaybackSourceResolver()

    private let registry: SecurityScopedLeaseRegistry
    private let bookmarkResolver: BookmarkResolver

    public init(
        registry: SecurityScopedLeaseRegistry = .shared,
        bookmarkResolver: @escaping BookmarkResolver = PlaybackSourceResolver.resolveBookmarkData
    ) {
        self.registry = registry
        self.bookmarkResolver = bookmarkResolver
    }

    public static func resolveBookmarkData(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale
        ) else { return nil }
        return (url, isStale)
    }

    /// Resolves the bookmark to a URL without starting access.
    public func bookmarkURL(_ data: Data) -> URL? {
        bookmarkResolver(data)?.url
    }

    public func resolve(_ chapter: Chapter) -> PlaybackSourceResolution {
        let failure = resolveLocal(chapter)
        switch failure {
        case .playableLocal:
            return failure
        default:
            if let remote = chapter.remoteURL { return .remoteFallback(remote) }
            return failure
        }
    }

    private func resolveLocal(_ chapter: Chapter) -> PlaybackSourceResolution {
        if let bookmark = chapter.localBookmark {
            guard let resolved = bookmarkResolver(bookmark) else { return .missingFile }
            if resolved.isStale { return .staleBookmark }
            guard let lease = registry.acquire(resolved.url) else { return .scopeDenied }
            switch Self.check(resolved.url) {
            case .playableLocal:
                return .playableLocal(resolved.url, lease: lease)
            case let other:
                lease.release()
                return other
            }
        }
        if let localURL = chapter.localURL {
            let local = ContainerPathRebase.rebase(localURL)
            // App-container files need no security scope. Keep the long-standing
            // behavior for them: a missing file with no remote still reaches the
            // engine, which surfaces the playback error (local file URLs never
            // touch the network). Typed failures apply to external bookmarks.
            let outcome = Self.check(local)
            if case .missingFile = outcome, chapter.remoteURL == nil {
                return .playableLocal(local, lease: nil)
            }
            return outcome
        }
        return chapter.remoteURL.map { .remoteFallback($0) } ?? .missingFile
    }

    private static func check(_ url: URL) -> PlaybackSourceResolution {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missingFile }
        guard fm.isReadableFile(atPath: url.path) else { return .unreadableFile }
        return .playableLocal(url, lease: nil)
    }
}
