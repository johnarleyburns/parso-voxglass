import Foundation

public struct SegmentQueueBuilder: Sendable {

    public func build(_ mode: PlaybackMode, from project: AudiobookProject, settings: AssemblySettings) -> [PlaybackSegment] {
        let chapterIDs: Set<UUID>
        let isReviewMode: Bool

        switch mode {
        case .wholeBook:
            chapterIDs = Set(project.chapters.map(\.id))
            isReviewMode = false
        case .chapter(let id):
            chapterIDs = [id]
            isReviewMode = false
        case .selectedChapters(let ids):
            chapterIDs = ids
            isReviewMode = false
        case .flagged, .needsPickup, .unapproved, .reviewQueue:
            isReviewMode = true
            let paragraphIDs = resolveParagraphIDs(mode, project: project)
            return buildFromParagraphIDs(paragraphIDs, project: project, settings: settings, isReviewMode: true)
        case .paragraphRange(let chapterID, _, _):
            chapterIDs = [chapterID]
            isReviewMode = false
        case .retailSample(let startParagraph, let maxDuration):
            return buildRetailSample(project: project, settings: settings, startParagraph: startParagraph, maxDuration: maxDuration)
        }

        var segments: [PlaybackSegment] = []
        var globalOrdinal = 0

        let orderedChapters = project.chapters.filter { chapterIDs.contains($0.id) }
            .sorted { $0.ordinal < $1.ordinal }

        for chapter in orderedChapters {
            let parsWithTakes = chapter.paragraphs.compactMap { p -> (Paragraph, Take)? in
                guard let selID = p.selectedTakeID, let take = p.takes.first(where: { $0.id == selID }) else { return nil }
                return (p, take)
            }

            if parsWithTakes.isEmpty { continue }

            for (idx, (paragraph, take)) in parsWithTakes.enumerated() {
                globalOrdinal += 1

                var leading: TimeInterval = 0
                var trailing: TimeInterval = 0

                // Silence semantics (spec §12.2): `leadingSilence` is written
                // before a segment and `trailingSilence` after it. To avoid
                // double-gapping between consecutive paragraphs (leading of one
                // plus trailing of the previous), the inter-paragraph gap is
                // carried by exactly one side: the `leadingSilence` of every
                // segment except the first carries the paragraph gap (plus any
                // scene-break extra), while `trailingSilence` is 0 for interior
                // segments and only the chapter tail is nonzero. Review modes
                // are the inverse: a tight 0.25 s turnaround with no leading.
                if isReviewMode {
                    trailing = 0.25
                    leading = 0
                } else {
                    if idx == 0 {
                        leading = chapter.headSilenceOverride ?? settings.chapterHeadSilence
                    } else {
                        leading = settings.paragraphGap
                        if paragraph.isSceneBreak {
                            leading += settings.sceneBreakExtraGap
                        }
                    }
                    trailing = 0
                }

                if idx == parsWithTakes.count - 1 && !isReviewMode {
                    trailing = chapter.tailSilenceOverride ?? settings.chapterTailSilence
                }

                // Assembly plan defaults (mockup 10 toggles, §11.1). Trims and
                // loudness come from the take's own measurements — never
                // guessed — and per-take explicit `processing` overrides them.
                var trimRange = 0.0..<take.duration
                var gain: Double = 0
                if settings.isTrimmingSilenceAtEdges, let m = take.metrics {
                    let leading = min(m.leadingSilence, take.duration * 0.5)
                    let trailing = min(m.trailingSilence, take.duration * 0.5)
                    if leading > 0 || trailing > 0 {
                        trimRange = leading..<max(leading, take.duration - trailing)
                    }
                }
                if settings.isNormalizingLoudness, let m = take.metrics {
                    gain = AssemblyLoudness.normalizationGainDB(for: m)
                }
                var fadeIn: TimeInterval = 0
                var fadeOut: TimeInterval = 0

                for step in take.processing {
                    switch step.kind {
                    case .trimStart:
                        if let val = step.parameters["seconds"] {
                            trimRange = val..<trimRange.upperBound
                        }
                    case .trimEnd:
                        if let val = step.parameters["seconds"] {
                            trimRange = trimRange.lowerBound..<(take.duration - val)
                        }
                    case .gainDB:
                        if let val = step.parameters["gain"] { gain = val }
                    case .fadeInSeconds:
                        if let val = step.parameters["seconds"] { fadeIn = val }
                    case .fadeOutSeconds:
                        if let val = step.parameters["seconds"] { fadeOut = val }
                    }
                }

                let segment = PlaybackSegment(
                    paragraphID: paragraph.id,
                    chapterID: chapter.id,
                    globalOrdinal: globalOrdinal,
                    assetRef: take.assetRef,
                    trim: max(0, trimRange.lowerBound)..<min(take.duration, max(trimRange.lowerBound, trimRange.upperBound)),
                    gainDB: gain,
                    fadeIn: fadeIn,
                    fadeOut: fadeOut,
                    leadingSilence: leading,
                    trailingSilence: trailing,
                    text: paragraph.text,
                    reviewState: paragraph.reviewState,
                    isContext: false
                )
                segments.append(segment)
            }
        }

        return segments
    }

    private func buildRetailSample(
        project: AudiobookProject,
        settings: AssemblySettings,
        startParagraph: UUID,
        maxDuration: TimeInterval
    ) -> [PlaybackSegment] {
        guard let chapter = project.chapters.first(where: { $0.paragraphs.contains { $0.id == startParagraph } }) else { return [] }
        let all = build(.chapter(chapter.id), from: project, settings: settings)
        guard let startIndex = all.firstIndex(where: { $0.paragraphID == startParagraph }) else { return [] }
        var sliced: [PlaybackSegment] = []
        var accumulated: TimeInterval = 0
        let target = max(60, min(300, maxDuration))
        for segment in all[startIndex...] {
            let duration = (segment.trim.upperBound - segment.trim.lowerBound) + segment.leadingSilence + segment.trailingSilence
            sliced.append(segment)
            accumulated += duration
            if accumulated >= target { break }
        }
        return sliced.isEmpty ? [] : sliced
    }

    private func resolveParagraphIDs(_ mode: PlaybackMode, project: AudiobookProject) -> [UUID] {
        let resolver = ReviewQueueResolver()
        let def: ReviewQueueDefinition
        switch mode {
        case .flagged:
            def = ReviewQueueDefinition(projectID: project.id, predicate: .flagged, order: .documentOrder)
        case .needsPickup:
            def = ReviewQueueDefinition(projectID: project.id, predicate: .needsPickup, order: .documentOrder)
        case .unapproved:
            def = ReviewQueueDefinition(projectID: project.id, predicate: .unapproved, order: .documentOrder)
        case .reviewQueue(let queueDef):
            def = queueDef
        default:
            return []
        }
        return resolver.resolve(def, in: project)
    }

    private func buildFromParagraphIDs(_ ids: [UUID], project: AudiobookProject, settings: AssemblySettings, isReviewMode: Bool) -> [PlaybackSegment] {
        var segments: [PlaybackSegment] = []
        var globalOrdinal = 0

        let lookup = paragraphLookup(project)

        for paraID in ids {
            guard let (paragraph, chapterID) = lookup[paraID],
                  let selID = paragraph.selectedTakeID,
                  let take = paragraph.takes.first(where: { $0.id == selID }) else { continue }

            globalOrdinal += 1

            var trimRange = 0.0..<take.duration
            var gain: Double = 0
            var fadeIn: TimeInterval = 0
            var fadeOut: TimeInterval = 0

            for step in take.processing {
                switch step.kind {
                case .trimStart:
                    if let val = step.parameters["seconds"] { trimRange = val..<trimRange.upperBound }
                case .trimEnd:
                    if let val = step.parameters["seconds"] { trimRange = trimRange.lowerBound..<(take.duration - val) }
                case .gainDB: if let val = step.parameters["gain"] { gain = val }
                case .fadeInSeconds: if let val = step.parameters["seconds"] { fadeIn = val }
                case .fadeOutSeconds: if let val = step.parameters["seconds"] { fadeOut = val }
                }
            }

            let segment = PlaybackSegment(
                paragraphID: paragraph.id,
                chapterID: chapterID,
                globalOrdinal: globalOrdinal,
                assetRef: take.assetRef,
                trim: max(0, trimRange.lowerBound)..<min(take.duration, max(trimRange.lowerBound, trimRange.upperBound)),
                gainDB: gain,
                fadeIn: fadeIn,
                fadeOut: fadeOut,
                leadingSilence: 0,
                trailingSilence: isReviewMode ? 0.25 : settings.paragraphGap,
                text: paragraph.text,
                reviewState: paragraph.reviewState,
                isContext: false
            )
            segments.append(segment)
        }

        return segments
    }

    private func paragraphLookup(_ project: AudiobookProject) -> [UUID: (Paragraph, UUID)] {
        var result: [UUID: (Paragraph, UUID)] = [:]
        for ch in project.chapters {
            for p in ch.paragraphs {
                result[p.id] = (p, ch.id)
            }
        }
        return result
    }

    public init() {}
}
