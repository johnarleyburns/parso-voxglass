import Foundation

public struct ScriptApplyReport: Sendable {
    public var inserted: Int = 0
    public var updated: Int = 0
    public var unchanged: Int = 0
    public var drifted: [UUID] = []
}

public struct ScriptApplier: Sendable {
    public init() {}

    public func apply(
        _ plan: ScriptPlan,
        to project: inout AudiobookProject,
        ids: any IDGenerator,
        clock: any Clock
    ) -> ScriptApplyReport {
        var report = ScriptApplyReport()
        let now = Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)

        for (chapterID, intro) in plan.chapterIntros {
            guard let chapterIndex = project.chapters.firstIndex(where: { $0.id == chapterID }) else { continue }

            // Every index is resolved against the live array at the moment of
            // use. A snapshot taken before the intro is inserted shifts every
            // later paragraph by one, which used to write the outro script over
            // the preceding — recorded — body paragraph.
            let introIndex = project.chapters[chapterIndex].paragraphs.firstIndex { $0.role == .libriVoxIntro }
            if let introIndex {
                write(intro, role: .libriVoxIntro, at: introIndex, chapterIndex: chapterIndex, in: &project, now: now, report: &report)
            } else {
                project.chapters[chapterIndex].paragraphs.insert(
                    Paragraph(
                        id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                        ordinal: 0,
                        text: intro,
                        textHash: TextNormalizer.hash(intro),
                        role: .libriVoxIntro,
                        updatedAt: now
                    ),
                    at: 0
                )
                report.inserted += 1
            }

            if let outro = plan.chapterOutros[chapterID] {
                let outroIndex = project.chapters[chapterIndex].paragraphs.lastIndex { $0.role == .libriVoxOutro }
                if let outroIndex {
                    write(outro, role: .libriVoxOutro, at: outroIndex, chapterIndex: chapterIndex, in: &project, now: now, report: &report)
                } else {
                    project.chapters[chapterIndex].paragraphs.append(
                        Paragraph(
                            id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                            ordinal: project.chapters[chapterIndex].paragraphs.count,
                            text: outro,
                            textHash: TextNormalizer.hash(outro),
                            role: .libriVoxOutro,
                            updatedAt: now
                        )
                    )
                    report.inserted += 1
                }
            }

            renumberOrdinals(in: &project.chapters[chapterIndex])
        }

        for synthetic in plan.bookChapters {
            if let chapterIndex = project.chapters.firstIndex(where: { $0.role == synthetic.role }) {
                // An existing credits chapter used to be counted as `updated`
                // and then left alone, so "Regenerate credits" never changed
                // anything and the stale-text rule could not clear.
                let paragraphIndex = project.chapters[chapterIndex].paragraphs.firstIndex { $0.role == synthetic.paragraphRole }
                    ?? project.chapters[chapterIndex].paragraphs.indices.first
                if let paragraphIndex {
                    write(
                        synthetic.paragraphText,
                        role: synthetic.paragraphRole,
                        at: paragraphIndex,
                        chapterIndex: chapterIndex,
                        in: &project,
                        now: now,
                        report: &report
                    )
                } else {
                    project.chapters[chapterIndex].paragraphs.append(
                        Paragraph(
                            id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                            ordinal: 0,
                            text: synthetic.paragraphText,
                            textHash: TextNormalizer.hash(synthetic.paragraphText),
                            role: synthetic.paragraphRole,
                            updatedAt: now
                        )
                    )
                    report.inserted += 1
                }
            } else {
                let chapterID = UUID(uuidString: ids.next().uuidString) ?? ids.next()
                let paragraph = Paragraph(
                    id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                    ordinal: 0,
                    text: synthetic.paragraphText,
                    textHash: TextNormalizer.hash(synthetic.paragraphText),
                    role: synthetic.paragraphRole,
                    updatedAt: now
                )

                let chapter = ProductionChapter(
                    id: chapterID,
                    ordinal: synthetic.role == .openingCredits ? 0 : project.chapters.count,
                    title: synthetic.title,
                    role: synthetic.role,
                    paragraphs: [paragraph]
                )
                project.chapters.append(chapter)
                report.inserted += 1
            }
        }

        project.modifiedAt = now

        return report
    }

    /// Applies planned script text to one paragraph, leaving the recording,
    /// review state and identity untouched. A no-op write is reported as
    /// `unchanged` so a second `apply` of the same plan is a fixpoint.
    private func write(
        _ text: String,
        role: ParagraphRole,
        at paragraphIndex: Int,
        chapterIndex: Int,
        in project: inout AudiobookProject,
        now: Date,
        report: inout ScriptApplyReport
    ) {
        let existing = project.chapters[chapterIndex].paragraphs[paragraphIndex]
        guard existing.text != text else {
            report.unchanged += 1
            return
        }
        project.chapters[chapterIndex].paragraphs[paragraphIndex].text = text
        project.chapters[chapterIndex].paragraphs[paragraphIndex].textHash = TextNormalizer.hash(text)
        project.chapters[chapterIndex].paragraphs[paragraphIndex].role = role
        project.chapters[chapterIndex].paragraphs[paragraphIndex].updatedAt = now
        report.updated += 1
        report.drifted.append(existing.id)
    }

    private func renumberOrdinals(in chapter: inout ProductionChapter) {
        for i in chapter.paragraphs.indices {
            chapter.paragraphs[i].ordinal = i
        }
    }
}
