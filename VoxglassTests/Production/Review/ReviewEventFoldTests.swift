import Foundation
import Testing
import VoxglassCore

/// Spec §19.3: ReviewEventFolder folds event streams into per-paragraph
/// review states, deterministically and idempotently, with the cross-device
/// needsPickup stickiness rule.
@Suite struct ReviewEventFoldTests {

    private let projectID = UUID()
    private let paraA = UUID()
    private let paraB = UUID()

    private func event(_ para: UUID, type: ReviewEventType, at t: TimeInterval, device: DeviceKind = .mac, note: String? = nil) -> ReviewEvent {
        ReviewEvent(
            projectID: projectID,
            paragraphID: para,
            type: type,
            noteText: note,
            device: device,
            createdAt: Date(timeIntervalSince1970: t)
        )
    }

    @Test func flagSetsFlagged() {
        let folder = ReviewEventFolder()
        let result = folder.fold([event(paraA, type: .flag, at: 0)], into: [:])
        #expect(result.states[paraA] == .flagged)
        #expect(result.changedParagraphIDs.contains(paraA))
    }

    @Test func unflagRestoresUnreviewed() {
        let folder = ReviewEventFolder()
        let result = folder.fold(
            [event(paraA, type: .flag, at: 0), event(paraA, type: .unflag, at: 1)],
            into: [:]
        )
        #expect(result.states[paraA] == .unreviewed)
    }

    @Test func approveSetsApproved() {
        let folder = ReviewEventFolder()
        let result = folder.fold([event(paraA, type: .approve, at: 0)], into: [:])
        #expect(result.states[paraA] == .approved)
    }

    @Test func needsPickupSetsNeedsPickupAndClearRestores() {
        let folder = ReviewEventFolder()
        let result = folder.fold(
            [event(paraA, type: .needsPickup, at: 0), event(paraA, type: .clearPickup, at: 1)],
            into: [:]
        )
        #expect(result.states[paraA] == .unreviewed)
    }

    @Test func addNoteFlagsUnreviewedParagraph() {
        let folder = ReviewEventFolder()
        let result = folder.fold([event(paraA, type: .addNote, at: 0, note: "fix this")], into: [:])
        #expect(result.states[paraA] == .flagged)
        #expect(result.notesToInsert.count == 1)
        #expect(result.notesToInsert.first?.text == "fix this")
        #expect(result.notesToInsert.first?.paragraphID == paraA)
    }

    @Test func eventsAppliedInTimeOrder() {
        let folder = ReviewEventFolder()
        // Out of order on purpose: approve first, then flag.
        let result = folder.fold(
            [event(paraA, type: .approve, at: 10), event(paraA, type: .flag, at: 0)],
            into: [:]
        )
        #expect(result.states[paraA] == .approved) // flag came first chronologically
    }

    @Test func crossDeviceApproveDoesNotOverrideFreshPickup() {
        let folder = ReviewEventFolder()
        let result = folder.fold(
            [
                event(paraA, type: .needsPickup, at: 100, device: .iPhone),
                event(paraA, type: .approve, at: 110, device: .mac),
            ],
            into: [:]
        )
        #expect(result.states[paraA] == .needsPickup)
    }

    @Test func sameDeviceApproveAfterPickupOverrides() {
        let folder = ReviewEventFolder()
        let result = folder.fold(
            [
                event(paraA, type: .needsPickup, at: 100, device: .mac),
                event(paraA, type: .approve, at: 110, device: .mac),
            ],
            into: [:]
        )
        #expect(result.states[paraA] == .approved)
    }

    @Test func foldIsDeterministic() {
        let folder = ReviewEventFolder()
        let events = [
            event(paraA, type: .flag, at: 0),
            event(paraA, type: .addNote, at: 1, note: "n"),
            event(paraB, type: .needsPickup, at: 2),
        ]
        let r1 = folder.fold(events, into: [:])
        let r2 = folder.fold(events, into: [:])
        #expect(r1.states == r2.states)
        // Note IDs are minted fresh per fold; compare the content, not the id.
        let content = { (n: ReviewNote) in [n.paragraphID.uuidString, n.text, n.device.rawValue] }
        #expect(r1.notesToInsert.map(content) == r2.notesToInsert.map(content))
    }

    @Test func initialStatesPreservedWhenNoEvent() {
        let folder = ReviewEventFolder()
        let result = folder.fold([], into: [paraA: .approved])
        #expect(result.states[paraA] == .approved)
        #expect(result.changedParagraphIDs.isEmpty)
    }
}
