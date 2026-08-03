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
                title: "Continue",
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
                    title: "No productions yet",
                    subtitle: "Productions you preview from Voxglass Studio on your Mac appear here.",
                    isEnabled: false,
                    action: .none
                )
            ]))
        } else {
            sections.append(ProductionCarPlaySection(
                header: "My Productions",
                items: Array(summaries.prefix(drivingItemCap)).map { summary in
                    ProductionCarPlayItem(
                        id: "carplay.production.\(summary.id.uuidString)",
                        title: summary.title,
                        subtitle: summary.flaggedCount > 0
                            ? "\(summary.flaggedCount) flagged · \(Int(summary.percentRecorded))% recorded"
                            : "\(Int(summary.percentRecorded))% recorded",
                        detailText: summary.readyToExport ? "Ready to export" : nil,
                        symbol: "book.closed.fill",
                        action: .openProduction(summary.id)
                    )
                }
            ))
        }
        return ProductionCarPlayTab(
            id: "carplay.tab.productions",
            title: "Productions",
            systemImage: "rectangle.stack.fill",
            sections: sections
        )
    }

    public static func reviewTab(summaries: [ProjectSummary]) -> ProductionCarPlayTab {
        let flagged = summaries.reduce(0) { $0 + $1.flaggedCount }
        return ProductionCarPlayTab(
            id: "carplay.tab.review",
            title: "Review",
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
            ProductionCarPlaySection(header: "Overview", items: [
                ProductionCarPlayItem(
                    id: "play-whole-book",
                    title: "Play Whole Book",
                    subtitle: "\(summary.recordedCount) of \(summary.totalCount) paragraphs recorded",
                    symbol: "play.circle.fill",
                    action: .playWholeBook
                ),
                ProductionCarPlayItem(
                    id: "review-flagged",
                    title: "Review \(summary.flaggedCount) Flagged",
                    subtitle: summary.flaggedCount > 0 ? "Start the flagged queue hands-free" : "Nothing flagged — everything reviewed is approved",
                    symbol: "flag.fill",
                    isEnabled: summary.flaggedCount > 0,
                    action: .startQueue(.flagged)
                )
            ]),
            ProductionCarPlaySection(header: "Chapters", items: [
                ProductionCarPlayItem(
                    id: "choose-chapter",
                    title: "Choose Chapter",
                    subtitle: "Jump to any chapter of the production",
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
                title: "Flagged",
                subtitle: "\(flaggedCount) paragraphs · \(WatchTimeFormat.duration(flaggedDuration))",
                symbol: "flag.fill",
                isEnabled: flaggedCount > 0,
                action: .startQueue(.flagged)
            ),
            ProductionCarPlayItem(
                id: "carplay.queue.pickup",
                title: "Needs Pickup",
                subtitle: "\(pickupCount) paragraphs",
                symbol: "arrow.triangle.2.circlepath",
                isEnabled: pickupCount > 0,
                action: .startQueue(.needsPickup)
            ),
            ProductionCarPlayItem(
                id: "carplay.queue.unapproved",
                title: "Unapproved",
                subtitle: "\(unapprovedCount) paragraphs",
                symbol: "circle",
                isEnabled: unapprovedCount > 0,
                action: .startQueue(.unapproved)
            )
        ]
        items.append(ProductionCarPlayItem(
            id: "queue-settings",
            title: "Review Settings",
            subtitle: "Auto-advance, context, audio confirmations",
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
                title: payload.chapterLabels[paragraphID] ?? "Paragraph",
                subtitle: [payload.tags[paragraphID].map(\.rawValue), payload.durations[paragraphID].map { CarPlayTimeFormat.compact($0) }]
                    .compactMap { $0 }.joined(separator: " · "),
                detailText: isCurrent ? "Playing" : payload.notes[paragraphID],
                symbol: isCurrent ? "play.circle.fill" : "chevron.right",
                action: isCurrent ? .none : .none
            )
        }
        return [ProductionCarPlaySection(header: "Queue \(payload.paragraphIDs.count)", items: Array(items))]
    }

    // MARK: - Note summary (mockup 05)

    public static func noteSummary(payload: ResolvedQueuePayload, index: Int) -> ProductionCarPlayNoteSummary {
        guard payload.paragraphIDs.indices.contains(index) else {
            return ProductionCarPlayNoteSummary(chapterLabel: "Paragraph")
        }
        let paragraphID = payload.paragraphIDs[index]
        return ProductionCarPlayNoteSummary(
            chapterLabel: payload.chapterLabels[paragraphID] ?? "Paragraph",
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
            ProductionCarPlaySection(header: "Playback", items: [
                ProductionCarPlayItem(
                    id: "carplay.settings.autoAdvance",
                    title: "Auto-advance after review action",
                    subtitle: "Move directly to the next queued paragraph.",
                    detailText: autoAdvance ? "On" : "Off",
                    symbol: autoAdvance ? "checkmark.circle.fill" : "circle",
                    action: .toggleAutoAdvance
                ),
                ProductionCarPlayItem(
                    id: "carplay.settings.playContext",
                    title: "Play one second of context",
                    subtitle: "Include nearby audio before and after the paragraph.",
                    detailText: context ? "On" : "Off",
                    symbol: context ? "checkmark.circle.fill" : "circle",
                    action: .toggleContext
                ),
                ProductionCarPlayItem(
                    id: "carplay.settings.audioConfirmations",
                    title: "Audio confirmations",
                    subtitle: "Play a short cue after each review action.",
                    detailText: voiceConfirmations ? "On" : "Off",
                    symbol: voiceConfirmations ? "checkmark.circle.fill" : "circle",
                    action: .toggleVoiceConfirmations
                )
            ]),
            ProductionCarPlaySection(header: "Driving Safety", items: [
                ProductionCarPlayItem(
                    id: "setting-safety-note",
                    title: "Typing and free-form note entry are unavailable in CarPlay. Detailed notes can be added later on iPhone, Watch, or Mac.",
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
        case .approveAndNext: title = "Paragraph Approved"
        case .needsPickupAndNext: title = "Paragraph Needs Pickup"
        case .keepFlaggedAndNext, .playNext, .undo: title = "Review Action"
        }
        return ProductionCarPlayConfirmation(
            title: title,
            message: "\(session.currentChapterLabel ?? "Paragraph") was updated.",
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
