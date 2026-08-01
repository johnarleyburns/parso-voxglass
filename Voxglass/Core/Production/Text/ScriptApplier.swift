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

        for (chapterID, intro) in plan.chapterIntros {
            guard let chapterIndex = project.chapters.firstIndex(where: { $0.id == chapterID }) else { continue }
            let chapter = project.chapters[chapterIndex]

            let existingIntro = chapter.paragraphs.first { $0.role == .libriVoxIntro }
            let existingOutro = chapter.paragraphs.last { $0.role == .libriVoxOutro }

            if let existing = existingIntro {
                if existing.text != intro {
                    var updated = existing
                    updated.text = intro
                    updated.textHash = TextNormalizer.hash(intro)
                    updated.updatedAt = Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)
                    if let paraIndex = chapter.paragraphs.firstIndex(where: { $0.id == existing.id }) {
                        project.chapters[chapterIndex].paragraphs[paraIndex] = updated
                    }
                    report.updated += 1
                    report.drifted.append(existing.id)
                } else {
                    report.unchanged += 1
                }
            } else {
                let newPara = Paragraph(
                    id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                    ordinal: 0,
                    text: intro,
                    textHash: TextNormalizer.hash(intro),
                    role: .libriVoxIntro,
                    updatedAt: Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)
                )
                project.chapters[chapterIndex].paragraphs.insert(newPara, at: 0)
                report.inserted += 1
            }

            if let outro = plan.chapterOutros[chapterID] {
                if let existing = existingOutro {
                    if existing.text != outro {
                        var updated = existing
                        updated.text = outro
                        updated.textHash = TextNormalizer.hash(outro)
                        updated.updatedAt = Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)
                        if let paraIndex = chapter.paragraphs.firstIndex(where: { $0.id == existing.id }) {
                            project.chapters[chapterIndex].paragraphs[paraIndex] = updated
                        }
                        report.updated += 1
                        report.drifted.append(existing.id)
                    } else {
                        report.unchanged += 1
                    }
                } else {
                    let newPara = Paragraph(
                        id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                        ordinal: chapter.paragraphs.count,
                        text: outro,
                        textHash: TextNormalizer.hash(outro),
                        role: .libriVoxOutro,
                        updatedAt: Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)
                    )
                    project.chapters[chapterIndex].paragraphs.append(newPara)
                    report.inserted += 1
                }
            }

            renumberOrdinals(in: &project.chapters[chapterIndex])
        }

        for synthetic in plan.bookChapters {
            let existingChapter = project.chapters.first { $0.role == synthetic.role }
            if let existing = existingChapter {
                if existing.paragraphs.first?.text != synthetic.paragraphText {
                    report.updated += 1
                } else {
                    report.unchanged += 1
                }
            } else {
                let chapterID = UUID(uuidString: ids.next().uuidString) ?? ids.next()
                let paragraph = Paragraph(
                    id: UUID(uuidString: ids.next().uuidString) ?? ids.next(),
                    ordinal: 0,
                    text: synthetic.paragraphText,
                    textHash: TextNormalizer.hash(synthetic.paragraphText),
                    role: synthetic.paragraphRole,
                    updatedAt: Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)
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

        let now = Date(timeIntervalSinceReferenceDate: clock.now.timeIntervalSinceReferenceDate)
        project.modifiedAt = now

        return report
    }

    private func renumberOrdinals(in chapter: inout ProductionChapter) {
        for i in chapter.paragraphs.indices {
            chapter.paragraphs[i].ordinal = i
        }
    }
}
