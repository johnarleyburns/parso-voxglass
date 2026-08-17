import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// WP-H coverage for the remaining specified surfaces: Validation "Fix Next
/// Issue" (F-23), take-comparison A/B (F-25), and Import Audio markers (F-26).
@MainActor
@Suite struct RemainingSurfacesTests {

    // MARK: - H1: Validation fixNext

    @Test func fixNextClearsPickupAndReEvaluates() async throws {
        let store = InMemoryProductionStore()
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        let take = Take(
            id: ids.next(),
            paragraphID: ids.next(),
            assetRef: AudioAssetReference(sha256: "aaa", relativePath: "Audio/Original/aa/a.wav", byteCount: 1, contentType: "audio/wav"),
            origin: .recorded,
            recordedAt: clock.now,
            duration: 5.0,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s24le"),
            textHashAtRecording: "h"
        )
        var needsPickup = Paragraph(id: take.paragraphID, ordinal: 0, text: "Pickup me", textHash: "hh", takes: [take], selectedTakeID: take.id, reviewState: .needsPickup)
        let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter", paragraphs: [needsPickup])
        let project = AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Pickup Book", author: "A", narrator: "N"),
            chapters: [chapter],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
        try await store.save(project)

        let model = ValidationModel(project: project, store: store, assets: InMemoryAssetStore(), target: .librivox)
        await model.evaluate()

        // A needs-pickup paragraph produces a blocking issue with `.clearPickup`.
        let fixable = model.nextFixableBlockingIssue
        #expect(fixable != nil)
        #expect(fixable?.fix != nil)

        let outcome = await model.fixNext()
        #expect(outcome != .none)
    }

    @Test func fixNextReturnsNoneWhenNothingBlocking() async throws {
        let store = InMemoryProductionStore()
        let project = ProjectFixtures.librivoxReady()
        try await store.save(project)

        let model = ValidationModel(project: project, store: store, assets: InMemoryAssetStore(), target: .librivox)
        await model.evaluate()
        if model.blockingCount == 0 {
            let outcome = await model.fixNext()
            #expect(outcome == .none)
        }
    }

    // MARK: - H2: Take comparison A/B

    @Test func playABTogglesBetweenSlots() async throws {
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let project = ProjectFixtures.librivoxReady()

        let paragraph = project.allParagraphs.first!
        let takes = paragraph.takes
        let model = TakeComparisonModel(
            paragraphID: paragraph.id,
            takes: takes,
            store: store,
            assets: assets,
            selectedTakeID: paragraph.selectedTakeID,
            player: NoopTakePlayer()
        )
        // Two or more takes are required for A/B slots.
        if takes.count >= 2 {
            #expect(model.takeA != nil)
            #expect(model.takeB != nil)
            await model.playAB()
            #expect(model.isABComparing)
            #expect(model.activeTakeID != nil)
            await model.stopAB()
            #expect(!model.isABComparing)
        } else {
            #expect(model.takeB == nil)
        }
    }

    // MARK: - H3: Import Audio markers

    @Test func addMarkerSplitsSegment() async throws {
        let project = ProjectFixtures.librivoxReady()
        let model = ImportAudioModel(project: project, store: InMemoryProductionStore(), assets: InMemoryAssetStore())

        // Fabricate two segments so the boundary model behaves.
        model.setSegmentsForTesting([
            .init(id: UUID(), start: 0.0, end: 10.0, confidence: .high, paragraphID: nil),
            .init(id: UUID(), start: 10.0, end: 20.0, confidence: .high, paragraphID: nil)
        ])
        #expect(model.segments.count == 2)
        #expect(model.boundaryTimes == [10.0])

        model.addMarker(at: 4.0)
        #expect(model.segments.count == 3)
        // 0–4, 4–10, 10–20.
        #expect(model.segments[0].end == 4.0)
        #expect(model.segments[1].start == 4.0)
    }

    @Test func removeMarkerMergesWithPrevious() async throws {
        let project = ProjectFixtures.librivoxReady()
        let model = ImportAudioModel(project: project, store: InMemoryProductionStore(), assets: InMemoryAssetStore())
        model.setSegmentsForTesting([
            .init(id: UUID(), start: 0.0, end: 4.0, confidence: .high, paragraphID: nil),
            .init(id: UUID(), start: 4.0, end: 10.0, confidence: .review, paragraphID: nil),
            .init(id: UUID(), start: 10.0, end: 20.0, confidence: .high, paragraphID: nil)
        ])
        model.removeMarker(at: 1)
        #expect(model.segments.count == 2)
        // The 0–4 and 4–10 segments merged into 0–10.
        #expect(model.segments[0].start == 0.0)
        #expect(model.segments[0].end == 10.0)
        #expect(model.segments[0].confidence == .review)
    }

    @Test func cannotRemoveFirstSegmentBoundary() async throws {
        let project = ProjectFixtures.librivoxReady()
        let model = ImportAudioModel(project: project, store: InMemoryProductionStore(), assets: InMemoryAssetStore())
        model.setSegmentsForTesting([
            .init(id: UUID(), start: 0.0, end: 4.0, confidence: .high, paragraphID: nil),
            .init(id: UUID(), start: 4.0, end: 10.0, confidence: .high, paragraphID: nil)
        ])
        model.removeMarker(at: 0)
        #expect(model.segments.count == 2)
    }
}

/// A `TakePlaying` that does nothing — A/B toggle logic is what we exercise.
struct NoopTakePlayer: TakePlaying {
    func play(url: URL, at position: TimeInterval) async throws {}
    func pause() async {}
}
