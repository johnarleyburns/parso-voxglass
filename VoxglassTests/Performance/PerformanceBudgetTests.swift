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
/// failures. The **only** invocations that set the variable are serialized ones —
/// CI (`.github/workflows/ios.yml`), the pre-commit/pre-push hooks, and
/// `scripts/test_logic.sh` — so the budgets cannot run un-serialized.
///
/// **Why the budgets are relative, not absolute.** Serialization removes the
/// contention the test run itself creates, but a shared dev machine can still be
/// saturated by unrelated processes (browser, chat apps, the editor), and an
/// absolute wall-clock budget then fails no matter how fast the engine is. Each
/// budget is therefore asserted as a **ratio between two input sizes of the same
/// workload** (e.g. 30 s of audio vs 3 s): the ratio is ~10 when the engine scales
/// linearly, under any uniform machine load, and blows past the margin on a
/// superlinear regression (the O(n²)-class the budgets exist to catch). A loose
/// absolute ceiling (3× the spec §19.7 number) still fails gross slowdowns.
/// Spec §19.3 describes this deviation.
///
/// Each side of the ratio is measured as the best of three interleaved runs, so
/// transient CI-runner jitter never produces a false failure.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["VOXGLASS_TIMING_TESTS"] == "1"))
struct PerformanceBudgetTests {

    /// The engine's documented linear-scaling factor between the small and large
    /// workloads (both are 10×), plus 20 % margin for fixed overheads.
    private static let linearMargin = 12.0

    private func timeAsync(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now()
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// Best-of-3 of each side, interleaved so both runs see the same machine load.
    private func bestPairAsync(
        _ large: () async throws -> Void,
        _ small: () async throws -> Void
    ) async rethrows -> (large: Double, small: Double) {
        var bestLarge = Double.greatestFiniteMagnitude
        var bestSmall = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            bestLarge = min(bestLarge, try await timeAsync(large))
            bestSmall = min(bestSmall, try await timeAsync(small))
        }
        return (bestLarge, bestSmall)
    }

    // MARK: - Spec §19.3 / §11.6.9 — audio metrics (30 s < 150 ms)

    @Test func thirtySecondTakeMetricsCompleteUnder150ms() async throws {
        let rate = 48000.0
        let long = sine(rate: rate, freq: 440, dur: 30.0, amp: 0.3)
        let short = sine(rate: rate, freq: 440, dur: 3.0, amp: 0.3)
        let calc = AudioMetricsCalculator(decoder: PlaceholderAudioDecoder())

        // Invariants once, outside the timing loop.
        let metrics = calc.metrics(for: long, sampleRate: rate, channels: 1)
        #expect(metrics.duration == 30.0)
        #expect(metrics.replayGainDB.isFinite)

        let pair = try await bestPairAsync(
            { _ = calc.metrics(for: long, sampleRate: rate, channels: 1) },
            { _ = calc.metrics(for: short, sampleRate: rate, channels: 1) }
        )
        #expect(
            pair.large < pair.small * Self.linearMargin,
            "30 s metrics took \(pair.large) ms vs \(pair.small) ms for 3 s — expected linear (≤ \(Self.linearMargin)×)"
        )
        #expect(pair.large < 450, "30 s metrics took \(pair.large) ms, ceiling is 450 ms (3× spec)")
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

    // MARK: - Spec §19.3 / §7.5 — store query budgets (< 120 ms / < 20 ms)

    private func onDiskStore(paragraphs: Int) async throws -> SQLiteProductionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SQLiteProductionStore(databaseURL: dir.appendingPathComponent("perf.sqlite"))
        let project = ProjectFixtures.stress(paragraphs: paragraphs)
        try await store.save(project)
        return store
    }

    @Test func paragraphSummariesUnder120ms() async throws {
        let large = try await onDiskStore(paragraphs: 10_000)
        let small = try await onDiskStore(paragraphs: 1_000)

        // Warm the page caches before measuring.
        _ = try await large.paragraphSummaries(chapterID: nil)
        _ = try await small.paragraphSummaries(chapterID: nil)
        #expect((try await large.paragraphSummaries(chapterID: nil)).count == 10_000)

        let pair = try await bestPairAsync(
            { _ = try await large.paragraphSummaries(chapterID: nil) },
            { _ = try await small.paragraphSummaries(chapterID: nil) }
        )
        #expect(
            pair.large < pair.small * Self.linearMargin,
            "paragraphSummaries took \(pair.large) ms on 10K vs \(pair.small) ms on 1K — expected linear (≤ \(Self.linearMargin)×)"
        )
        #expect(pair.large < 360, "paragraphSummaries took \(pair.large) ms, ceiling is 360 ms (3× spec)")
    }

    @Test func countsUnder20ms() async throws {
        let large = try await onDiskStore(paragraphs: 10_000)
        let small = try await onDiskStore(paragraphs: 1_000)
        _ = try await large.counts()
        _ = try await small.counts()
        #expect((try await large.counts()).paragraphs == 10_000)

        let pair = try await bestPairAsync(
            { _ = try await large.counts() },
            { _ = try await small.counts() }
        )
        #expect(
            pair.large < pair.small * Self.linearMargin,
            "counts() took \(pair.large) ms on 10K vs \(pair.small) ms on 1K — expected linear (≤ \(Self.linearMargin)×)"
        )
        #expect(pair.large < 60, "counts() took \(pair.large) ms, ceiling is 60 ms (3× spec)")
    }

    // MARK: - Spec §19.3 — 10,000-¶ re-import (< 2 s)

    /// The document is built so every heading level is a real chapter boundary,
    /// so chapter formation does not collapse (T32 regression guard).
    private func importDocument(paragraphCount: Int) -> ExtractedDocument {
        var plainText = ""
        var blocks: [ExtractedBlock] = []
        var offset = 0
        for i in 0..<paragraphCount {
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
        return ExtractedDocument(
            sections: [ExtractedSection(heading: "Book", blocks: blocks, sourceStart: 0)],
            plainText: plainText
        )
    }

    @Test func tenThousandParagraphReimportUnder2Seconds() async throws {
        let large = importDocument(paragraphCount: 10_000)
        let small = importDocument(paragraphCount: 1_000)

        let result = Segmenter().segment(large, ids: SequentialIDGenerator(), clock: FixedClock())
        #expect(result.chapters.count == 100)
        #expect(result.stats.paragraphCount == 10_000)

        let pair = try await bestPairAsync(
            { _ = Segmenter().segment(large, ids: SequentialIDGenerator(), clock: FixedClock()) },
            { _ = Segmenter().segment(small, ids: SequentialIDGenerator(), clock: FixedClock()) }
        )
        #expect(
            pair.large < pair.small * Self.linearMargin,
            "10K re-import took \(pair.large) ms vs \(pair.small) ms for 1K — expected linear (≤ \(Self.linearMargin)×)"
        )
        #expect(pair.large < 6_000, "10K re-import took \(pair.large) ms, ceiling is 6 s (3× spec)")
    }

    // MARK: - Spec §19.3 — 10,000-¶ reidentification (< 8 s)

    /// The reidentification pass over the 10,000-¶ fixture (previously asserted
    /// inline in the parallel `ReidentificationTests`, where CPU contention
    /// made the 8 s wall-clock budget flaky — moved here per the serialization
    /// policy).
    private func reidentifierParagraph(_ id: UUID, _ text: String, ordinal: Int = 0) -> Paragraph {
        Paragraph(
            id: id,
            ordinal: ordinal,
            text: text,
            textHash: TextNormalizer.hash(text),
            role: .body
        )
    }

    private func reidentifierBlock(_ text: String, start: Int = 0) -> ExtractedBlock {
        ExtractedBlock(kind: .paragraph, text: text, sourceRange: start..<(start + text.count))
    }

    private func reidentifierFixture(paragraphCount: Int) -> (existing: [Paragraph], incoming: [ExtractedBlock]) {
        var existing: [Paragraph] = []
        var incoming: [ExtractedBlock] = []
        for i in 0..<paragraphCount {
            let id = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012x", i))")!
            let text = "This is the lengthy content of paragraph number \(i) which contains many words to ensure that jaccard similarity computations are representative of real world paragraph structures and lengths for audiobook productions."
            existing.append(reidentifierParagraph(id, text, ordinal: i))
            incoming.append(reidentifierBlock(text))
        }
        return (existing, incoming)
    }

    @Test func tenThousandParagraphReidentificationUnder8Seconds() async throws {
        let large = reidentifierFixture(paragraphCount: 10_000)
        let small = reidentifierFixture(paragraphCount: 1_000)

        let report = ParagraphReidentifier().match(existing: large.existing, incoming: large.incoming)
        #expect(report.assignments.count >= 9_999)

        let pair = try await bestPairAsync(
            { _ = ParagraphReidentifier().match(existing: large.existing, incoming: large.incoming) },
            { _ = ParagraphReidentifier().match(existing: small.existing, incoming: small.incoming) }
        )
        #expect(
            pair.large < pair.small * Self.linearMargin,
            "10K reidentification took \(pair.large) ms vs \(pair.small) ms for 1K — expected linear (≤ \(Self.linearMargin)×)"
        )
        #expect(pair.large < 24_000, "10K reidentification took \(pair.large) ms, ceiling is 24 s (3× spec)")
    }

    // MARK: - Spec §19.3 / §15.4 — full validation (3,000 ¶ < 2 s)

    /// The pure rule engine's metrics input for the stress fixture: every
    /// selected take gets one valid metric so audio rules run, not just the
    /// `missingMetrics` fallback.
    private func validationMetrics(_ project: AudiobookProject) -> [UUID: AudioQualityMetrics] {
        var dict: [UUID: AudioQualityMetrics] = [:]
        for p in project.allParagraphs {
            guard let sid = p.selectedTakeID, let take = p.takes.first(where: { $0.id == sid }) else { continue }
            dict[take.id] = AudioQualityMetrics(
                peakDBFS: -3, truePeakDBFS: -4, rmsDBFS: -20, noiseFloorDBFS: -65,
                clipCount: 0, dcOffset: 0, leadingSilence: 0.1, trailingSilence: 0.2,
                duration: 5, sampleRate: 48_000, channels: 1
            )
        }
        return dict
    }

    private func validate(_ project: AudiobookProject, target: DestinationID) {
        _ = ValidationRuleEngine().evaluate(
            project: project,
            metrics: validationMetrics(project),
            profile: DestinationProfile.profile(for: target),
            eligibility: EligibilityProfile.evaluate(project),
            assembly: project.profile.assembly
        )
    }

    /// §15.4's 2 s budget, asserted the repo's documented way (§22.4): a
    /// load-independent ratio between a 3,000-¶ and a 300-¶ project, plus a
    /// 3× absolute ceiling. S7 acceptance also requires the `typical()` fixture
    /// to be deterministic for all five destinations — that lives in
    /// `ValidationDeterminismTests` (parallel, no clock).
    @Test func fullValidationOfThreeThousandParagraphs() async throws {
        let large = ProjectFixtures.stress(paragraphs: 3_000)
        let small = ProjectFixtures.stress(paragraphs: 300)

        let count = ValidationRuleEngine().evaluate(
            project: large,
            metrics: validationMetrics(large),
            profile: DestinationProfile.profile(for: .acx),
            eligibility: EligibilityProfile.evaluate(large),
            assembly: large.profile.assembly
        )
        #expect(!count.isEmpty)

        let pair = try await bestPairAsync(
            { validate(large, target: .acx) },
            { validate(small, target: .acx) }
        )
        #expect(
            pair.large < pair.small * Self.linearMargin,
            "validation took \(pair.large) ms on 3K vs \(pair.small) ms on 300 — expected linear (≤ \(Self.linearMargin)×)"
        )
        #expect(pair.large < 6_000, "validation took \(pair.large) ms on 3K, ceiling is 6 s (3× spec)")
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
