import CarPlay
import UIKit
import VoxglassCore

/// Mechanical `ProductionCarPlay*` value node → real `CP*` template translation,
/// mirroring `CarPlayTemplateRenderer` for the production surface. No decisions:
/// every choice was already made by `ProductionCarPlayBuilder`.
@MainActor
enum ProductionCarPlayRenderer {

    typealias ActionHandler = @MainActor (ProductionCarPlayAction) -> Void

    static func tabBar(tabs: [ProductionCarPlayTab], handler: @escaping ActionHandler) -> CPTabBarTemplate {
        CPTabBarTemplate(templates: tabs.map { tabTemplate($0, handler: handler) })
    }

    static func tabTemplate(_ tab: ProductionCarPlayTab, handler: @escaping ActionHandler) -> CPListTemplate {
        let template = CPListTemplate(
            title: tab.title,
            sections: sections(tab.sections, handler: handler)
        )
        template.tabTitle = tab.title
        template.tabImage = UIImage(systemName: tab.systemImage)
        return template
    }

    static func listTemplate(
        title: String,
        sections modelSections: [ProductionCarPlaySection],
        handler: @escaping ActionHandler
    ) -> CPListTemplate {
        CPListTemplate(title: title, sections: sections(modelSections, handler: handler))
    }

    static func sections(
        _ modelSections: [ProductionCarPlaySection],
        handler: @escaping ActionHandler
    ) -> [CPListSection] {
        modelSections.map { section in
            CPListSection(
                items: section.items.map { item in
                    let listItem = CPListItem(
                        text: item.title,
                        detailText: item.detailText ?? item.subtitle
                    )
                    listItem.isEnabled = item.isEnabled
                    if case .none = item.action {
                        // Static row: nothing to do.
                    } else {
                        listItem.handler = { _, completion in
                            handler(item.action)
                            completion()
                        }
                    }
                    return listItem
                },
                header: section.header,
                sectionIndexTitle: nil
            )
        }
    }

    static func noteSummaryTemplate(_ summary: ProductionCarPlayNoteSummary) -> CPInformationTemplate {
        let items: [CPInformationItem] = [
            CPInformationItem(title: "Note", detail: summary.noteText ?? "No note for this paragraph"),
            CPInformationItem(title: "Playback", detail: summary.paragraphText ?? summary.chapterLabel)
        ]
        return CPInformationTemplate(
            title: summary.chapterLabel,
            layout: .twoColumn,
            items: items,
            actions: []
        )
    }

    static func confirmationAlert(
        _ confirmation: ProductionCarPlayConfirmation,
        playNext: @escaping () -> Void,
        undo: @escaping () -> Void
    ) -> CPAlertTemplate {
        let playNextAction = CPAlertAction(
            title: "Play Next",
            style: .default,
            handler: { _ in playNext() }
        )
        let undoAction = CPAlertAction(
            title: "Undo",
            style: .cancel,
            handler: { _ in undo() }
        )
        var titleVariants = [confirmation.title, confirmation.message]
        if let next = confirmation.nextParagraphLabel {
            titleVariants.append("Next: \(next)")
        }
        return CPAlertTemplate(titleVariants: titleVariants, actions: [playNextAction, undoAction])
    }

    static func nowPlayingTemplate(
        reviewButtonIDs: [(id: String, image: UIImage)],
        handler: @escaping @MainActor (CarPlayReviewCommand) -> Void
    ) -> (template: CPNowPlayingTemplate, ids: [String]) {
        let template = CPNowPlayingTemplate.shared
        var ids: [String] = []
        let buttons: [CPNowPlayingButton] = reviewButtonIDs.map { id, image in
            ids.append(id)
            return CPNowPlayingImageButton(image: image) { _ in
                switch id {
                case CarPlayReviewButtonID.approve:
                    handler(.approveAndNext)
                case CarPlayReviewButtonID.pickup:
                    handler(.needsPickupAndNext)
                default:
                    handler(.keepFlaggedAndNext)
                }
            }
        }
        template.updateNowPlayingButtons(buttons)
        return (template, ids)
    }
}

public enum CarPlayReviewButtonID {
    public static let keepFlagged = "carplay.keepFlagged"
    public static let approve = "carplay.approve"
    public static let pickup = "carplay.pickup"
}
