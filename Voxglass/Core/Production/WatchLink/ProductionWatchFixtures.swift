import Foundation

/// Deterministic fixtures for the watch relay — used by `WatchPayloadTests` /
/// `WatchEventRelayTests` and by the watch smoke seed (`-uiTestSeed watchQueue`).
/// All IDs and timestamps are fixed so tests and the UI smoke path never observe
/// nondeterminism (spec §19.6, G-7).
public enum ProductionWatchFixtures {

    public static let rogerAckroydSlug = "rogerAckroyd"
    public static let rogerAckroydTitle = "The Murder of Roger Ackroyd"
    public static let rogerAckroydProjectID = UUID(uuidString: "0CA6F57D-6B41-4C38-A8F9-000000000001")!

    public static let queueFlagged = "Flagged"
    public static let queuePickup = "Needs Pickup"
    public static let queueUnapproved = "Unapproved"

    private static let clockStart = Date(timeIntervalSince1970: 1_700_000_000)
    private static let revision = 42

    /// The `.watchQueue` seed: one production with 18 flagged paragraphs, 7 pickups.
    public static func watchQueueSeed() -> (summaries: [ProjectSummary], queue: ResolvedQueuePayload, audio: [WatchAudioItem]) {
        (summaries: summaries(), queue: flaggedQueue(), audio: audioItems(for: flaggedParagraphIDs))
    }

    public static func summaries() -> [ProjectSummary] {
        [
            ProjectSummary(
                id: rogerAckroydProjectID,
                title: rogerAckroydTitle,
                author: "Agatha Christie",
                narrator: "A. Narrator",
                percentRecorded: 42,
                recordedCount: 296,
                totalCount: 705,
                flaggedCount: 18,
                needsPickupCount: 7,
                unapprovedCount: 31,
                readyToExport: false,
                purpose: .publicDomainCommunity,
                modifiedAt: clockStart,
                coverRef: nil,
                isHiddenFromDevices: false,
                projectionRevision: revision
            )
        ]
    }

    public static let flaggedParagraphIDs: [UUID] = (0..<18).map { paragraphID($0) }

    public static func flaggedQueue() -> ResolvedQueuePayload {
        let ids = flaggedParagraphIDs
        var texts: [UUID: String] = [:]
        var notes: [UUID: String] = [:]
        var durations: [UUID: TimeInterval] = [:]
        var chapterLabels: [UUID: String] = [:]
        var tags: [UUID: ReviewTag] = [:]

        let sampleTexts = [
            "Poirot leaned forward and placed one hand upon the table.",
            "The letter had no date, and the writing was cramped and almost illegible.",
            "She spoke in a low voice, as though she were afraid of being overheard.",
            "I was quite certain that the door had been bolted on the inside.",
            "The facts of the case, as far as I knew them, were these.",
            "A chair was drawn up to the table, and beside it the fire burned brightly."
        ]
        let sampleNotes = [
            "Pronounce Poirot more softly; second syllable too sharp.",
            "Drop the pace here; the reveal lands flat.",
            "Take a breath before the last clause.",
            "Too quiet after the burst of laughter.",
            nil
        ]

        for (index, id) in ids.enumerated() {
            texts[id] = sampleTexts[index % sampleTexts.count]
            notes[id] = sampleNotes[index % sampleNotes.count]
            durations[id] = TimeInterval(12 + (index % 9) * 3)
            let chapter = index / 6 + 1
            chapterLabels[id] = "Chapter \(chapter) · ¶ \(218 + index)"
            tags[id] = [ReviewTag.pronunciation, .pacing, .misread, .noise][index % 4]
        }

        return ResolvedQueuePayload(
            projectID: rogerAckroydProjectID,
            projectTitle: rogerAckroydTitle,
            queueLabel: queueFlagged,
            paragraphIDs: ids,
            texts: texts,
            notes: notes,
            durations: durations,
            chapterLabels: chapterLabels,
            tags: tags,
            autoAdvance: true,
            revision: revision
        )
    }

    public static func audioItems(for paragraphIDs: [UUID]) -> [WatchAudioItem] {
        paragraphIDs.enumerated().map { index, id in
            WatchAudioItem(
                paragraphID: id,
                sha256: String(format: "%064d", index + 1),
                byteCount: 8_000 + (index % 7) * 500,
                fileURL: nil
            )
        }
    }

    public static func paragraphID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "0CA6F57D-6B41-4C38-A8F9-%012d", 1_000 + index))!
    }
}
