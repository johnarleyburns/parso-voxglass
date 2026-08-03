import Foundation
import VoxglassCore

/// The iOS concrete of the `HTTPFetching` seam (NARRATION_NEEDS_SPEC §4.2).
/// App-target only; `Discovery/**` Core code never touches URLSession directly
/// (G-17). Detects auth-wall redirects so L3 yields nothing on a sign-in wall.
public struct URLSessionFetcher: HTTPFetching {
    public init() {}

    public func get(_ url: URL, timeout: TimeInterval, userAgent: String) async throws -> HTTPFetchResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .ephemeral, delegate: RedirectObserver(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPFetchError.transport
            }
            return HTTPFetchResult(
                data: data,
                statusCode: http.statusCode,
                finalURL: http.url ?? url
            )
        } catch is CancellationError {
            throw HTTPFetchError.timeout
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw HTTPFetchError.timeout
            case .cancelled:
                throw HTTPFetchError.timeout
            default:
                throw HTTPFetchError.transport
            }
        }
    }
}

/// Observes redirects so a hop toward a sign-in page can be reported as an
/// auth wall (L3 → nothing).
private final class RedirectObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let host = request.url?.host?.lowercased(),
           host.contains("librivox.org"),
           let path = request.url?.path.lowercased(),
           path.contains("ucp.php") || path.contains("login") {
            completionHandler(nil) // abort the redirect — treat as a sign-in wall
        } else {
            completionHandler(request)
        }
    }
}
