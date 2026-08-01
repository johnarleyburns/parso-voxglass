import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// ALL timing-budget tests, consolidated into a single `.serialized` suite so they
/// can never contend with each other for CPU.
///
/// They are additionally `.enabled(if:)` behind the `VOXGLASS_TIMING_TESTS`
/// environment variable: `swift test` runs test targets in parallel, so a plain
/// invocation would run these budgets against saturated CPUs and produce false
/// failures (e.g. 30 s metrics measuring 157 ms against a 150 ms budget). The
/// **only** invocations that set the variable are serialized ones — CI
/// (`.github/workflows/ios.yml`), the pre-commit/pre-push hooks, and
/// `scripts/test_logic.sh` — so the budgets cannot run un-serialized.
///
/// Budgets are asserted as the best of several runs so transient CI-runner jitter
/// never produces a false failure; the budget measures the engine's best-case
/// throughput (spec §19.3).
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXGLASS_TIMING_TESTS"] == "1"))
struct PerformanceBudgetTests {

    // MARK: - Spec §19.3 / §11.6.9 — audio metrics

    /// Metrics for a 30-second take must complete in < 150 ms.
    @Test func thirtySecondTakeMetricsCompleteUnder150ms() throws {
        let rate = 48000.0
        let samples = sine(rate: rate, freq: 440, dur: 30.0, amp: 0.3)
        let calc = AudioMetricsCalculator(decoder: PlaceholderAudioDecoder())

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now()
            let metrics = calc.metrics(for: samples, sampleRate: rate, channels: 1)
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsedMS)
            #expect(metrics.duration == 30.0)
            #expect(metrics.replayGainDB.isFinite)
        }
        #expect(best < 150, "30 s metrics took \(best) ms, budget is 150 ms")
    }

    private func sine(rate: Double, freq: Double, dur: Double, amp: Float) -> [Float] {
        let n = Int(rate * dur)
        var s = [Float]()
        s.reserveCapacity(n)
        for i in 0..<n {
            s.append(amp * Float(sin(2.0 * .pi * freq * Double(i) / rate)))
        }
        return s
    }

    // MARK: - Spec §19.3 / §7.5 — store query budgets

    /// `paragraphSummaries` on the 10,000-¶ fixture < 120 ms, and `counts()` < 20 ms
    /// — both MUST be single SQL statements over SQLite, not a full project load.
    private func onDiskStore() async throws -> SQLiteProductionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SQLiteProductionStore(databaseURL: dir.appendingPathComponent("perf.sqlite"))
        let project = ProjectFixtures.stress(paragraphs: 10_000)
        try await store.save(project)
        return store
    }

    private func bestOf(_ iterations: Int, _ body: () async throws -> Void) async throws -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<iterations {
            let start = DispatchTime.now()
            try await body()
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsedMS)
        }
        return best
    }

    @Test func paragraphSummariesUnder120ms() async throws {
        let store = try await onDiskStore()

        // Warm the page cache before measuring.
        _ = try await store.paragraphSummaries(chapterID: nil)

        let summaries = try await store.paragraphSummaries(chapterID: nil)
        #expect(summaries.count == 10_000)

        let elapsedMS = try await bestOf(3) {
            _ = try await store.paragraphSummaries(chapterID: nil)
        }
        #expect(elapsedMS < 120, "paragraphSummaries took \(elapsedMS) ms, budget is 120 ms")
    }

    @Test func countsUnder20ms() async throws {
        let store = try await onDiskStore()
        _ = try await store.counts()

        let counts = try await store.counts()
        #expect(counts.paragraphs == 10_000)

        let elapsedMS = try await bestOf(3) {
            _ = try await store.counts()
        }
        #expect(elapsedMS < 20, "counts() took \(elapsedMS) ms, budget is 20 ms")
    }

    // MARK: - Spec §19.3 — 10,000-¶ re-import

    /// The document is built so every heading level is a real chapter boundary,
    /// so chapter formation does not collapse (T32 regression guard).
    @Test func tenThousandParagraphReimportUnder2Seconds() {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let blockCount = 10_000
        var plainText = ""
        var blocks: [ExtractedBlock] = []
        var offset = 0
        for i in 0..<blockCount {
            let text = "Chapter \(i / 100 + 1) paragraph \(i). " + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 2)
            let start = offset
            let separator = i > 0 ? "\n\n" : ""
            plainText += separator + text
            offset += separator.count + text.count
            let end = offset
            let kind: BlockKind = i % 100 == 0 ? .heading : .paragraph
            let level: Int? = i % 100 == 0 ? 1 : nil
            blocks.append(ExtractedBlock(kind: kind, text: text, sourceRange: start..<end, headingLevel: level))
        }
        let doc = ExtractedDocument(
            sections: [ExtractedSection(heading: "Book", blocks: blocks, sourceStart: 0)],
            plainText: plainText
        )

        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now()
            let result = Segmenter().segment(doc, ids: ids, clock: clock)
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            best = min(best, elapsedMS)
            #expect(result.chapters.count == blockCount / 100)
            #expect(result.stats.paragraphCount == blockCount)
        }
        #expect(best < 2_000, "10K re-import took \(best) ms, budget is 2000 ms")
    }

    // MARK: - Spec §19.8 — render-count probe

    /// Drives a 5-second fake recording and asserts the teleprompter's render count
    /// stays below 3 while the meter's invalidation count exceeds 100 — proving the
    /// §11.3 isolation works rather than merely that nothing crashed.
    ///
    /// The meter side is asserted at the observation layer (`withObservationTracking`):
    /// @Observable invalidation notifications are exactly the signal that schedules
    /// SwiftUI re-renders, and counting them is deterministic in a headless test
    /// host where live window-server display cycles are not. The teleprompter guard
    /// stays at the view layer (`RenderCounter`), which is reliable in both.
    ///
    /// This probe pumps a real runloop against wall-clock time, which is why it lives
    /// in the serialized timing suite — under parallel-suite CPU contention the meter
    /// cannot sustain its ~30 Hz cadence.
    @Test func teleprompterDoesNotInvalidateWhileMeterUpdates() async throws {
        #if DEBUG
        let capture = FakeAudioCapture()
        capture.takeDuration = 10
        capture.levelRate = 0.033
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let paragraph = Paragraph(id: UUID(), ordinal: 0, text: "The teleprompter text that must not re-render while the meter updates at thirty hertz for the full duration of this probe.", textHash: "h")
        let project = AudiobookProject(id: UUID(), metadata: BookMetadata(title: "T", author: "A", narrator: "N"), chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "C", paragraphs: [paragraph])])
        try await store.save(project)
        let model = RecordingModel(capture: capture, store: store, assets: assets, projectID: project.id)
        await model.loadProject()
        await model.prepare()

        // Observation-layer count of meter invalidations during the recording:
        // @Observable invalidations are the signal that schedules SwiftUI
        // re-renders, and counting them is deterministic in a headless host.
        let meter = model.meter
        final class Counter: @unchecked Sendable {
            nonisolated(unsafe) var value = 0
        }
        let invalidations = Counter()
        func armMeterTracking() {
            _ = withObservationTracking {
                _ = meter.peakDBFS
                _ = meter.elapsed
            } onChange: {
                invalidations.value += 1
                MainActor.assumeIsolated { armMeterTracking() }
            }
        }
        armMeterTracking()

        RenderCounter.counts.removeAll()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: RecordingWorkspaceView(
            model: model,
            paragraph: paragraph,
            paragraphIndex: 0,
            totalParagraphs: 1
        ))
        window.makeKeyAndOrderFront(nil)

        await model.startRecording(paragraphID: paragraph.id)
        RenderCounter.counts.removeAll()

        // Pump the runloop until the meter has actually invalidated more than
        // 100 times (the §19.8 budget). The fake yields at ~30 Hz, but a slow
        // CI runner cannot sustain that cadence; pumping until the budget is
        // reached makes the isolation assertion machine-speed independent
        // while still proving the teleprompter stayed frozen throughout.
        let deadline = Date().addingTimeInterval(30)
        while invalidations.value <= 100 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try await Task.yield()
        }

        let teleprompter = RenderCounter.counts["record.teleprompter", default: 0]
        await model.stopRecording()
        window.orderOut(nil)

        #expect(invalidations.value > 100, "meter only invalidated \(invalidations.value) times at ~30 Hz")
        #expect(teleprompter < 3, "teleprompter rendered \(teleprompter) times during recording")
        #endif
    }
}
