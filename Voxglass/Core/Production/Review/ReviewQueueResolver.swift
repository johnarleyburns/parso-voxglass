import Foundation

public struct ReviewQueueResolver: Sendable {

    public func resolve(_ def: ReviewQueueDefinition, in project: AudiobookProject) -> [UUID] {
        let allParagraphs = project.chapters.flatMap { ch in
            ch.paragraphs.map { ($0, ch.id) }
        }

        var filtered: [(paragraph: Paragraph, chapterID: UUID)] = allParagraphs.filter { p, chID in
            if let chapterIDs = def.chapterIDs, !chapterIDs.contains(chID) {
                return false
            }
            switch def.predicate {
            case .allRecorded:
                return p.selectedTakeID != nil
            case .flagged:
                return p.reviewState == .flagged
            case .needsPickup:
                return p.reviewState == .needsPickup
            case .unapproved:
                return p.selectedTakeID != nil && p.reviewState != .approved
            case .unreviewed:
                return p.selectedTakeID != nil && p.reviewState == .unreviewed
            case .selectedParagraphs(let ids):
                return ids.contains(p.id)
            case .chapter(let chapterFilter):
                return chapterFilter == chID
            case .tag(let tag):
                return p.selectedTakeID != nil
            }
        }

        // Secondary tag filter (applied after primary predicate)
        if case .tag(let tag) = def.predicate {
            filtered = filtered.filter { _ in false } // tag-based filtering via notes done at store level
        }

        switch def.order {
        case .documentOrder:
            filtered.sort { a, b in
                let aGlob = project.globalOrdinal(of: a.paragraph.id) ?? 0
                let bGlob = project.globalOrdinal(of: b.paragraph.id) ?? 0
                return aGlob < bGlob
            }
        case .byChapter:
            filtered.sort { a, b in
                let aCh = project.chapterIndex(of: a.chapterID) ?? 0
                let bCh = project.chapterIndex(of: b.chapterID) ?? 0
                if aCh != bCh { return aCh < bCh }
                return a.paragraph.ordinal < b.paragraph.ordinal
            }
        case .flaggedFirst:
            filtered.sort { a, b in
                let aScore = statePriority(a.paragraph.reviewState)
                let bScore = statePriority(b.paragraph.reviewState)
                if aScore != bScore { return aScore > bScore }
                let aGlob = project.globalOrdinal(of: a.paragraph.id) ?? 0
                let bGlob = project.globalOrdinal(of: b.paragraph.id) ?? 0
                return aGlob < bGlob
            }
        case .shortestFirst:
            filtered.sort { a, b in
                let aDur = a.paragraph.selectedTake?.duration ?? .infinity
                let bDur = b.paragraph.selectedTake?.duration ?? .infinity
                return aDur < bDur
            }
        }

        return filtered.map(\.paragraph.id)
    }

    private func statePriority(_ state: ReviewState) -> Int {
        switch state {
        case .flagged: return 3
        case .needsPickup: return 2
        case .unreviewed: return 1
        case .approved: return 0
        }
    }

    public init() {}
}

extension AudiobookProject {
    func globalOrdinal(of paragraphID: UUID) -> Int? {
        var ordinal = 0
        for ch in chapters {
            for p in ch.paragraphs {
                ordinal += 1
                if p.id == paragraphID { return ordinal }
            }
        }
        return nil
    }

    func chapterIndex(of chapterID: UUID) -> Int? {
        chapters.firstIndex { $0.id == chapterID }
    }
}

extension Paragraph {
    var selectedTake: Take? {
        guard let id = selectedTakeID else { return nil }
        return takes.first { $0.id == id }
    }
}
