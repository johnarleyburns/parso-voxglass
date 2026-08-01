import Foundation

public struct ParagraphSplitter: Sendable {
    public init() {}

    public func split(
        _ paragraph: Paragraph,
        atCharacterOffset: Int,
        ids: any IDGenerator,
        clock: any Clock
    ) -> (first: Paragraph, second: Paragraph) {
        let clamped = max(0, min(atCharacterOffset, paragraph.text.count))
        let firstText = String(paragraph.text.prefix(clamped))
        let secondText = String(paragraph.text.suffix(paragraph.text.count - clamped))

        let firstID = paragraph.id
        let secondID = UUID(uuidString: ids.next().uuidString) ?? ids.next()
        let now = Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)

        let first = Paragraph(
            id: firstID,
            ordinal: paragraph.ordinal,
            text: firstText,
            textHash: TextNormalizer.hash(firstText),
            role: paragraph.role,
            directionNote: paragraph.directionNote,
            pronunciationRefs: paragraph.pronunciationRefs,
            takes: paragraph.takes,
            selectedTakeID: paragraph.selectedTakeID,
            reviewState: paragraph.reviewState,
            isSceneBreak: paragraph.isSceneBreak,
            updatedAt: now
        )

        let second = Paragraph(
            id: secondID,
            ordinal: paragraph.ordinal + 1,
            text: secondText,
            textHash: TextNormalizer.hash(secondText),
            role: paragraph.role,
            directionNote: paragraph.directionNote,
            pronunciationRefs: paragraph.pronunciationRefs,
            takes: [],
            selectedTakeID: nil,
            reviewState: .unreviewed,
            isSceneBreak: false,
            updatedAt: now
        )

        return (first, second)
    }

    public func merge(_ a: Paragraph, _ b: Paragraph, clock: any Clock) -> Paragraph {
        let mergedText = a.text + "\n" + b.text
        let worseState = worseReviewState(a.reviewState, b.reviewState)
        let now = Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)

        let mergedTakes = a.takes + b.takes.map { take in
            var t = take
            t.isArchived = true
            t.label = "From merged ¶" + (t.label.map { " \($0)" } ?? "")
            return t
        }

        let mergedDirection = [a.directionNote, b.directionNote].compactMap { $0 }.joined(separator: "\n").nilIfEmpty

        return Paragraph(
            id: a.id,
            ordinal: a.ordinal,
            text: mergedText,
            textHash: TextNormalizer.hash(mergedText),
            role: a.role,
            directionNote: mergedDirection,
            pronunciationRefs: Array(Set(a.pronunciationRefs + b.pronunciationRefs)),
            takes: mergedTakes,
            selectedTakeID: a.selectedTakeID,
            reviewState: worseState,
            isSceneBreak: a.isSceneBreak || b.isSceneBreak,
            updatedAt: now
        )
    }

    private func worseReviewState(_ a: ReviewState, _ b: ReviewState) -> ReviewState {
        let order: [ReviewState] = [.needsPickup, .flagged, .unreviewed, .approved]
        let aIdx = order.firstIndex(of: a) ?? 0
        let bIdx = order.firstIndex(of: b) ?? 0
        return order[min(aIdx, bIdx)]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
