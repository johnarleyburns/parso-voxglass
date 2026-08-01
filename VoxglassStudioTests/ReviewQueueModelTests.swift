import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
import VoxglassStudioKit

/// Spec §18.1.10 / §14: the review queue resolves once, holds stable, marks
/// excluded items done in place, and expresses every action as an event.
@Suite @MainActor struct ReviewQueueModelTests {

    private func makeProject() -> AudiobookProject {
        let clock = FixedClock()
        var paragraphs: [Paragraph] = []
        let states: [ReviewState] = [.flagged, .flagged, .needsPickup, .approved, .unreviewed, .unreviewed]
        let recorded: [Bool] = [true, true, true, true, true, false]

        for (i, state) in states.enumerated() {
            let pid = UUID()
            var takes: [Take] = []
            var selectedTakeID: UUID? = nil
            if recorded[i] {
                let take = Take(
                    id: UUID(),
                    paragraphID: pid,
                    assetRef: AudioAssetReference(
                        sha256: SHA256Hex.hex(Data("take-\(i)".utf8)),
                        relativePath: "Audio/Original/ab/cd/\(i).wav",
                        byteCount: 100,
                        contentType: "audio/wav"
                    ),
                    origin: .recorded,
                    recordedAt: clock.now,
                    duration: 4.0,
                    format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
                    textHashAtRecording: "h"
                )
                takes = [take]
                selectedTakeID = take.id
            }
            paragraphs.append(Paragraph(
                id: pid,
                ordinal: i,
                text: "Paragraph \(i) for review.",
                textHash: "h",
                takes: takes,
                selectedTakeID: selectedTakeID,
                reviewState: state
            ))
        }

        return AudiobookProject(
            id: UUID(),
            metadata: BookMetadata(title: "Review Test", author: "A", narrator: "N"),
            chapters: [
                ProductionChapter(id: UUID(), ordinal: 0, title: "Chapter One", paragraphs: paragraphs)
            ],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    private func makeModel() async throws -> (model: ReviewQueueModel, store: InMemoryProductionStore, project: AudiobookProject) {
        let project = makeProject()
        let store = InMemoryProductionStore()
        try await store.save(project)
        let model = ReviewQueueModel(
            project: project,
            store: store,
            assets: InMemoryAssetStore(),
            player: FakeSegmentPlayer()
        )
        return (model, store, project)
    }

    @Test func loadPopulatesQueueInDocumentOrder() async throws {
        let (model, _, project) = try await makeModel()
        await model.load(predicate: .flagged)

        let flagged = project.allParagraphs.filter { $0.reviewState == .flagged }.map(\.id)
        #expect(model.items.count == 2)
        #expect(model.items.map(\.id) == flagged)
        #expect(model.currentIndex == 0)
        #expect(model.currentParagraph?.id == flagged[0])
    }

    @Test func approveAndNextEmitsApproveAndAdvances() async throws {
        let (model, store, project) = try await makeModel()
        await model.load(predicate: .flagged)

        let firstID = project.allParagraphs.filter { $0.reviewState == .flagged }[0].id
        await model.approveAndNext()

        let events = (try? await store.unappliedEvents()) ?? []
        #expect(events.contains { $0.type == .approve && $0.paragraphID == firstID })

        #expect(model.items[0].isDone == true)
        #expect(model.currentIndex == 1)
        #expect(model.items[1].id != firstID)
    }

    @Test func needsPickupEmitsPickupEvent() async throws {
        let (model, store, project) = try await makeModel()
        await model.load(predicate: .needsPickup)

        let pickupID = project.allParagraphs.first { $0.reviewState == .needsPickup }!.id
        await model.needsPickupAndNext()

        let events = (try? await store.unappliedEvents()) ?? []
        #expect(events.contains { $0.type == .needsPickup && $0.paragraphID == pickupID })
        #expect(model.items[0].isDone == true)
    }

    @Test func keepFlaggedAdvancesWithoutEmittingEvent() async throws {
        let (model, store, _) = try await makeModel()
        await model.load(predicate: .flagged)

        let eventsBefore = (try? await store.unappliedEvents()) ?? []
        await model.keepFlagged()

        let eventsAfter = (try? await store.unappliedEvents()) ?? []
        #expect(eventsAfter.count == eventsBefore.count)
        #expect(model.currentIndex == 1)
    }

    @Test func submitNoteEmitsAddNoteWithText() async throws {
        let (model, store, _) = try await makeModel()
        await model.load(predicate: .flagged)

        model.noteText = "pronounce more softly"
        await model.submitNote()

        let events = (try? await store.unappliedEvents()) ?? []
        let noteEvent = events.first { $0.type == .addNote }
        #expect(noteEvent?.noteText == "pronounce more softly")
        #expect(model.noteText.isEmpty)
        #expect(model.notes.contains { $0.text == "pronounce more softly" })
    }
}
