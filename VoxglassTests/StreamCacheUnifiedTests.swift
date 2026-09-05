import Testing
import Foundation
import ParsoAudioStreaming
@testable import VoxglassCore

/// Integration coverage for Voxglass on the shared `ParsoAudioStreaming` cache
/// (parso-audio-engine Phase 2). Runs under `swift test`, i.e. on every commit
/// via the pre-commit hook — this is where the old manual streaming smoke steps
/// ("stream, background, replay from cache"; "download, kill network, play";
/// "clear cache") now live.
///
/// The library owns the store-mechanics tests (`SparseCacheStoreTests`); these
/// assert Voxglass's *wiring*: its key identity, the durable/offline tier, the
/// artwork kind, the preset budget, and a real loader round-trip.
@Suite(.serialized)
struct StreamCacheUnifiedTests {

    // MARK: - URLProtocol range stub

    final class RangeStub: URLProtocol {
        /// `URLProtocol` calls in from arbitrary threads, so the shared fixture
        /// state is lock-protected rather than a bare mutable global.
        private final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var _blob = Data()
            private var _offline = false
            private var _requestCount = 0

            var blob: Data {
                get { lock.lock(); defer { lock.unlock() }; return _blob }
                set { lock.lock(); defer { lock.unlock() }; _blob = newValue }
            }
            var offline: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _offline }
                set { lock.lock(); defer { lock.unlock() }; _offline = newValue }
            }
            var requestCount: Int {
                get { lock.lock(); defer { lock.unlock() }; return _requestCount }
                set { lock.lock(); defer { lock.unlock() }; _requestCount = newValue }
            }
        }
        private static let state = State()

        static var blob: Data {
            get { state.blob }
            set { state.blob = newValue }
        }
        static var offline: Bool {
            get { state.offline }
            set { state.offline = newValue }
        }
        static var requestCount: Int {
            get { state.requestCount }
            set { state.requestCount = newValue }
        }

        static func reset(blob: Data) {
            self.blob = blob; offline = false; requestCount = 0
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.requestCount += 1
            if Self.offline {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let total = Self.blob.count
            var status = 200
            var body = Self.blob
            var headers = ["Content-Type": "audio/mpeg"]
            if let spec = request.value(forHTTPHeaderField: "Range")?.split(separator: "=").last {
                let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
                let lower = Int(parts.first ?? "") ?? 0
                let upper = min((parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1), total - 1)
                if lower <= upper {
                    body = Self.blob.subdata(in: lower..<(upper + 1))
                    status = 206
                    headers["Content-Range"] = "bytes \(lower)-\(upper)/\(total)"
                }
            }
            headers["Content-Length"] = String(body.count)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RangeStub.self]
        return URLSession(configuration: cfg)
    }

    private func makeStore(limit: Int64 = SparseCacheStore.defaultLimit) -> SparseCacheStore {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-cache-\(UUID().uuidString)", isDirectory: true)
        return SparseCacheStore(evictableRoot: base.appendingPathComponent("stream"),
                                durableRoot: base.appendingPathComponent("offline"),
                                limitBytes: limit)
    }

    private func poll(_ c: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if await c() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("condition not met in time")
    }

    // MARK: - Wiring

    @Test func voxglassKeyKeepsTheHistoricalShape() {
        // No extension → bare hash; with extension → hash-ext. (The Tonearm
        // strategy always keeps a trailing separator; Voxglass must not.)
        let bare = AudioCache.key(for: URL(string: "https://archive.org/download/x/stream")!)
        let ext = AudioCache.key(for: URL(string: "https://archive.org/download/x/ch1.mp3")!)
        #expect(!bare.contains("-"))
        #expect(ext.hasSuffix("-mp3"))
    }

    @Test func streamedChapterReplaysFromCacheWithNetworkGone() async throws {
        RangeStub.reset(blob: Data((0..<8192).map { UInt8($0 & 0xff) }))
        let store = makeStore()
        let url = URL(string: "https://archive.org/download/book/ch1.mp3")!
        let loader = CachingResourceLoader(
            originalURL: url, store: store,
            config: .init(scheme: AudioCache.scheme, keyStrategy: AudioCache.keyStrategy),
            session: stubSession())

        loader.warm(upTo: 8192)
        await poll { await store.rangeMap(for: loader.cacheKey).contiguousBytes(from: 0) >= 8192 }
        loader.shutdown()

        RangeStub.offline = true
        let countAfterFill = RangeStub.requestCount

        #expect(await store.cachedContiguousBytes(for: loader.cacheKey, from: 0) == 8192)
        let onDisk = try Data(contentsOf: await store.fileURL(for: loader.cacheKey))
        #expect(onDisk == RangeStub.blob)
        #expect(RangeStub.requestCount == countAfterFill)
    }

    @Test func offlineDownloadSurvivesAnOverBudgetEviction() async {
        let store = makeStore(limit: 10_000)
        await store.setContentLength(100, for: "offline-mp3")
        await store.recordWrite(range: 0..<100, for: "offline-mp3")
        await store.pin(["offline-mp3"])                        // → durable tier

        await store.setContentLength(300, for: "stream-mp3")
        await store.recordWrite(range: 0..<300, for: "stream-mp3")

        await store.setLimit(120)   // streaming budget now exceeded by stream-mp3 alone

        #expect(await store.contains("offline-mp3"))            // pinned content is safe
        #expect(!(await store.contains("stream-mp3")))          // evictable content is dropped
    }

    @Test func artworkBytesCountButAreNotTracks() async {
        let store = makeStore()
        await store.registerComplete(key: "art_a", bytes: 400, kind: "artwork")
        await store.setContentLength(100, for: "chapter-mp3")
        await store.recordWrite(range: 0..<100, for: "chapter-mp3")

        #expect(await store.totalCachedBytes() == 500)
        #expect(await store.completeEntryCount(kind: "audio") == 1)
        #expect(await store.completeEntryCount(kind: "artwork") == 1)
    }

    @Test func presetSelectionReappliesTheBudget() async {
        // Uses the real (shared) store; restore the previous preset afterwards.
        let previous = AudioCache.CachePreset.selected
        defer { Task { await AudioCache.CachePreset.select(previous) } }

        await AudioCache.CachePreset.select(.g2GB)
        #expect(await AudioCache.shared.currentLimit() == AudioCache.CachePreset.g2GB.rawValue)
        #expect(AudioCache.CachePreset.selected == .g2GB)
    }

    @Test func clearCacheEmptiesTheStore() async {
        let store = makeStore()
        await store.setContentLength(10, for: "a-mp3")
        await store.recordWrite(range: 0..<10, for: "a-mp3")
        await store.registerComplete(key: "art_x", bytes: 20, kind: "artwork")

        await store.clearAll()
        #expect(await store.totalCachedBytes() == 0)
        #expect(!(await store.contains("a-mp3")))
    }
}
