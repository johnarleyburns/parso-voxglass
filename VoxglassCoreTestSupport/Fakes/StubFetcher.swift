import Foundation
import VoxglassCore

/// Deterministic, inspectable `HTTPFetching` fake for discovery source tests.
/// Routes are keyed by absolute URL; a default route covers everything else.
/// Requests are recorded for assertions. Configurable to fail (transport,
/// timeout, auth wall) — never touches the network.
public final class StubFetcher: HTTPFetching, @unchecked Sendable {
    public struct Route: Sendable {
        public var result: HTTPFetchResult?
        public var delay: TimeInterval
        public var error: HTTPFetchError?

        public init(result: HTTPFetchResult? = nil, delay: TimeInterval = 0, error: HTTPFetchError? = nil) {
            self.result = result
            self.delay = delay
            self.error = error
        }
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var defaultRoute: Route?
    public private(set) var recordedRequests: [URL] = []

    public init() {}

    /// Registers a response for an exact URL.
    @discardableResult
    public func route(_ url: URL, result: HTTPFetchResult?, error: HTTPFetchError? = nil, delay: TimeInterval = 0) -> StubFetcher {
        lock.withLock {
            routes[url.absoluteString] = Route(result: result, delay: delay, error: error)
        }
        return self
    }

    /// Sets the fallback route for any unregistered URL.
    @discardableResult
    public func setDefault(_ route: Route) -> StubFetcher {
        lock.withLock { defaultRoute = route }
        return self
    }

    /// Makes every request fail — simulates the all-sources-down case.
    @discardableResult
    public func failAll(_ error: HTTPFetchError = .transport) -> StubFetcher {
        lock.withLock { defaultRoute = Route(error: error) }
        return self
    }

    public func get(_ url: URL, timeout: TimeInterval, userAgent: String) async throws -> HTTPFetchResult {
        let route = lock.withLock {
            recordedRequests.append(url)
            return routes[url.absoluteString] ?? defaultRoute
        }
        if let error = route?.error {
            throw error
        }
        if let delay = route?.delay, delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        if let result = route?.result {
            return result
        }
        throw HTTPFetchError.transport
    }
}

public extension StubFetcher {
    convenience init(url: URL, data: Data, statusCode: Int = 200, finalURL: URL? = nil) {
        self.init()
        route(url, result: HTTPFetchResult(data: data, statusCode: statusCode, finalURL: finalURL ?? url))
    }
}
