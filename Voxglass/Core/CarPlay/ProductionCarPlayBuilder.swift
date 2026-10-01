import Foundation

/// Pure static builders for the CarPlay production surface. No I/O, no store
/// references — summaries and queue payloads come in, value trees go out, so every
/// decision (tab order, item caps, empty states, the settings safety note) is
/// asserted host-side under `swift test`.
public enum ProductionCarPlayBuilder {

    /// CarPlay truncates long lists while the car is moving; we cap ourselves so
    /// the tail is never silently dropped by the system mid-queue.
    public static let drivingItemCap = 12

    // MARK: - Root

    /// The three-tab production root: Continue / Productions / Review.
    public static func rootTabs(
        continueSections: [CarPlaySection],
        summaries: [ProjectSummary]
    ) -> [ProductionCarPlayTab] {
        [
            ProductionCarPlayTab(
                id: "carplay.tab.continue",
                title: String(localized: "Continue", bundle: .module),
                systemImage: "arrow.clockwise.circle.fill",
                sections: continueSections.map {
                    ProductionCarPlaySection(header: $0.header, items: $0.items.map {
                        ProductionCarPlayItem(
                            id: $0.id,
                            title: $0.title,
                            subtitle: $0.subtitle,
                            detailText: $0.detailText,
                            symbol: "play.circle.fill",
                            isEnabled: $0.isEnabled,
                            action: .none
                        )
                    })
                }
            ),
            productionsTab(summaries: summaries),
            reviewTab(summaries: summaries)
        ]
    }

    public static func productionsTab(summaries: [ProjectSummary]) -> ProductionCarPlayTab {
        var sections: [ProductionCarPlaySection] = []
        if summaries.isEmpty {
            sections.append(ProductionCarPlaySection(items: [
                ProductionCarPlayItem(
                    id: "empty-productions",
                    title: String(localized: "No productions yet", bundle: .module),
                    subtitle: String(localized: "Productions you start in Voxglass on iPhone appear here.", bundle: .module),
                    isEnabled: false,
                    action: .none
                )
            ]))
        } else {
            sections.append(ProductionCarPlaySection(
                header: String(localized: "My Productions", bundle: .module),
                items: Array(summaries.prefix(drivingItemCap)).map { summary in
                    ProductionCarPlayItem(
                        id: "carplay.production.\(summary.id.uuidString)",
                        title: summary.title,
                        subtitle: summary.flaggedCount > 0
                            ? String(localized: "\(summary.flaggedCount) flagged · \(Int(summary.percentRecorded))% recorded", bundle: .module)
                            : String(localized: "\(Int(summary.percentRecorded))% recorded", bundle: .module),
                        detailText: summary.readyToExport ? String(localized: "Ready to export", bundle: .module) : nil,
                        symbol: "book.closed.fill",
                        action: .openProduction(summary.id)
                    )
                }
            ))
        }
        return ProductionCarPlayTab(
            id: "carplay.tab.productions",
            title: String(localized: "Productions", bundle: .module),
            systemImage: "rectangle.stack.fill",
            sections: sections
        )
    }

    public static func reviewTab(summaries: [ProjectSummary]) -> ProductionCarPlayTab {
        let flagged = summaries.reduce(0) { $0 + $1.flaggedCount }
        return ProductionCarPlayTab(
            id: "carplay.tab.review",
            title: String(localized: "Review", bundle: .module),
            systemImage: "checkmark.circle.fill",
            badge: flagged,
            sections: queueListSections(
                payload: nil,
                flaggedCount: flagged,
                pickupCount: summaries.reduce(0) { $0 + $1.needsPickupCount },
                unapprovedCount: summaries.reduce(0) { $0 + $1.unapprovedCount }
            )
        )
    }

    // MARK: - Production detail (mockup 02)

    public static func productionDetail(_ summary: ProjectSummary) -> [ProductionCarPlaySection] {
        [
            ProductionCarPlaySection(header: String(localized: "Overview", bundle: .module), items: [
                ProductionCarPlayItem(
                    id: "play-whole-book",
                    title: String(localized: "Play Whole Book", bundle: .module),
                    subtitle: String(localized: "\(summary.recordedCount) of \(summary.totalCount) paragraphs recorded", bundle: .module),
                    symbol: "play.circle.fill",
                    action: .playWholeBook
                ),
                ProductionCarPlayItem(
                    id: "review-flagged",
                    title: String(localized: "Review \(summary.flaggedCount) Flagged", bundle: .module),
                    subtitle: summary.flaggedCount > 0 ? String(localized: "Start the flagged queue hands-free", bundle: .module) : String(localized: "Nothing flagged — everything reviewed is approved", bundle: .module),
                    symbol: "flag.fill",
                    isEnabled: summary.flaggedCount > 0,
                    action: .startQueue(.flagged)
                )
            ]),
            ProductionCarPlaySection(header: String(localized: "Chapters", bundle: .module), items: [
                ProductionCarPlayItem(
                    id: "choose-chapter",
                    title: String(localized: "Choose Chapter", bundle: .module),
                    subtitle: String(localized: "Jump to any chapter of the production", bundle: .module),
                    symbol: "list.bullet",
                    action: .none
                )
            ])
        ]
    }

    // MARK: - Review queues (mockup 03)

    public static func queueListSections(
        payload: ResolvedQueuePayload?,
        flaggedCount: Int,
        pickupCount: Int,
        unapprovedCount: Int
    ) -> [ProductionCarPlaySection] {
        let flaggedDuration = payload.map { queueDuration($0) } ?? 0
        var items: [ProductionCarPlayItem] = [
            ProductionCarPlayItem(
                id: "carplay.queue.flagged",
                title: String(localized: "Flagged", bundle: .module),
                subtitle: String(localized: "\(flaggedCount) paragraphs · \(WatchTimeFormat.duration(flaggedDuration))", bundle: .module),
                symbol: "flag.fill",
                isEnabled: flaggedCount > 0,
                action: .startQueue(.flagged)
            ),
            ProductionCarPlayItem(
                id: "carplay.queue.pickup",
                title: String(localized: "Needs Pickup", bundle: .module),
                subtitle: String(localized: "\(pickupCount) paragraphs", bundle: .module),
                symbol: "arrow.triangle.2.circlepath",
                isEnabled: pickupCount > 0,
                action: .startQueue(.needsPickup)
            ),
            ProductionCarPlayItem(
                id: "carplay.queue.unapproved",
                title: String(localized: "Unapproved", bundle: .module),
                subtitle: String(localized: "\(unapprovedCount) paragraphs", bundle: .module),
                symbol: "circle",
                isEnabled: unapprovedCount > 0,
                action: .startQueue(.unapproved)
            )
        ]
        items.append(ProductionCarPlayItem(
            id: "queue-settings",
            title: String(localized: "Review Settings", bundle: .module),
            subtitle: String(localized: "Auto-advance, context, audio confirmations", bundle: .module),
            symbol: "gearshape.fill",
            action: .openSettings
        ))
        return [ProductionCarPlaySection(items: items)]
    }

    // MARK: - Queue browser (mockup 07)

    public static func queueBrowserSections(
        payload: ResolvedQueuePayload,
        currentIndex: Int
    ) -> [ProductionCarPlaySection] {
        let items = payload.paragraphIDs.enumerated().prefix(drivingItemCap).map { index, paragraphID in
            let isCurrent = index == currentIndex
            return ProductionCarPlayItem(
                id: paragraphID.uuidString,
                title: payload.chapterLabels[paragraphID] ?? String(localized: "Paragraph", bundle: .module),
                subtitle: [payload.tags[paragraphID].map(\.rawValue), payload.durations[paragraphID].map { CarPlayTimeFormat.compact($0) }]
                    .compactMap { $0 }.joined(separator: " · "),
                detailText: isCurrent ? String(localized: "Playing", bundle: .module) : payload.notes[paragraphID],
                symbol: isCurrent ? "play.circle.fill" : "chevron.right",
                action: isCurrent ? .none : .none
            )
        }
        return [ProductionCarPlaySection(header: String(localized: "Queue \(payload.paragraphIDs.count)", bundle: .module), items: Array(items))]
    }

    // MARK: - Note summary (mockup 05)

    public static func noteSummary(payload: ResolvedQueuePayload, index: Int) -> ProductionCarPlayNoteSummary {
        guard payload.paragraphIDs.indices.contains(index) else {
            return ProductionCarPlayNoteSummary(chapterLabel: String(localized: "Paragraph", bundle: .module))
        }
        let paragraphID = payload.paragraphIDs[index]
        return ProductionCarPlayNoteSummary(
            chapterLabel: payload.chapterLabels[paragraphID] ?? String(localized: "Paragraph", bundle: .module),
            paragraphText: payload.texts[paragraphID],
            noteText: payload.notes[paragraphID],
            tag: payload.tags[paragraphID],
            sourceLabel: "iPhone",
            timeLabel: ""
        )
    }

    // MARK: - Settings (mockup 08)

    public static func settingsSections(
        autoAdvance: Bool,
        context: Bool,
        voiceConfirmations: Bool
    ) -> [ProductionCarPlaySection] {
        [
            ProductionCarPlaySection(header: String(localized: "Playback", bundle: .module), items: [
                ProductionCarPlayItem(
                    id: "carplay.settings.autoAdvance",
                    title: String(localized: "Auto-advance after review action", bundle: .module),
                    subtitle: String(localized: "Move directly to the next queued paragraph.", bundle: .module),
                    detailText: autoAdvance ? String(localized: "On", bundle: .module) : String(localized: "Off", bundle: .module),
                    symbol: autoAdvance ? "checkmark.circle.fill" : "circle",
                    action: .toggleAutoAdvance
                ),
                ProductionCarPlayItem(
                    id: "carplay.settings.playContext",
                    title: String(localized: "Play one second of context", bundle: .module),
                    subtitle: String(localized: "Include nearby audio before and after the paragraph.", bundle: .module),
                    detailText: context ? String(localized: "On", bundle: .module) : String(localized: "Off", bundle: .module),
                    symbol: context ? "checkmark.circle.fill" : "circle",
                    action: .toggleContext
                ),
                ProductionCarPlayItem(
                    id: "carplay.settings.audioConfirmations",
                    title: String(localized: "Audio confirmations", bundle: .module),
                    subtitle: String(localized: "Play a short cue after each review action.", bundle: .module),
                    detailText: voiceConfirmations ? String(localized: "On", bundle: .module) : String(localized: "Off", bundle: .module),
                    symbol: voiceConfirmations ? "checkmark.circle.fill" : "circle",
                    action: .toggleVoiceConfirmations
                )
            ]),
            ProductionCarPlaySection(header: String(localized: "Driving Safety", bundle: .module), items: [
                ProductionCarPlayItem(
                    id: "setting-safety-note",
                    title: String(localized: "Typing and free-form note entry are unavailable in CarPlay. Detailed notes can be added later on iPhone or Watch.", bundle: .module),
                    isEnabled: false,
                    action: .none
                )
            ])
        ]
    }

    // MARK: - Confirmation (mockup 06)

    public static func confirmation(
        command: CarPlayReviewCommand,
        session: CarPlayReviewSession
    ) -> ProductionCarPlayConfirmation {
        let title: String
        switch command {
        case .approveAndNext: title = String(localized: "Paragraph Approved", bundle: .module)
        case .needsPickupAndNext: title = String(localized: "Paragraph Needs Pickup", bundle: .module)
        case .keepFlaggedAndNext, .playNext, .undo: title = String(localized: "Review Action", bundle: .module)
        }
        return ProductionCarPlayConfirmation(
            title: title,
            message: String(localized: "\(session.currentChapterLabel ?? "Paragraph") was updated.", bundle: .module),
            nextParagraphLabel: session.nextParagraphLabel
        )
    }

    // MARK: - Helpers

    public static func queueDuration(_ payload: ResolvedQueuePayload) -> TimeInterval {
        payload.paragraphIDs.reduce(0) { total, id in
            total + (payload.durations[id] ?? 0)
        }
    }
}
