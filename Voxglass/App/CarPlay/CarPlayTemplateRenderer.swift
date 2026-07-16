import CarPlay
import UIKit
import VoxglassCore

/// Mechanical `CarPlay*` value node → real `CP*` template translation with no
/// decisions (docs/CARPLAY_DESIGN.md §6.5). Every interesting choice was
/// already made by `CarPlayMenuBuilder`; this maps fields one-to-one. The one
/// smoke test (§8) instantiates real `CP*` objects through this renderer.
@MainActor
enum CarPlayTemplateRenderer {

    struct Dispatcher {
        let dispatch: @MainActor (CarPlayAction) -> Void

        static let noop = Dispatcher(dispatch: { _ in })
    }

    struct ArtworkSource {
        let image: @MainActor (URL) async -> UIImage?

        static let noop = ArtworkSource(image: { _ in nil })
        static let shared = ArtworkSource(image: { url in
            await ArtworkService.shared.image(for: url)
        })
    }

    static func render(
        _ interface: CarPlayInterface,
        dispatcher: Dispatcher,
        artwork: ArtworkSource
    ) -> CPTabBarTemplate {
        CPTabBarTemplate(templates: interface.tabs.map {
            tabTemplate($0, dispatcher: dispatcher, artwork: artwork)
        })
    }

    static func tabTemplate(
        _ tab: CarPlayTab,
        dispatcher: Dispatcher,
        artwork: ArtworkSource
    ) -> CPListTemplate {
        let template = CPListTemplate(
            title: tab.title,
            sections: sections(tab.sections, dispatcher: dispatcher, artwork: artwork)
        )
        template.tabTitle = tab.title
        template.tabImage = UIImage(systemName: tab.systemImage)
        return template
    }

    static func listTemplate(
        title: String,
        sections modelSections: [CarPlaySection],
        dispatcher: Dispatcher,
        artwork: ArtworkSource
    ) -> CPListTemplate {
        CPListTemplate(
            title: title,
            sections: sections(modelSections, dispatcher: dispatcher, artwork: artwork)
        )
    }

    static func sections(
        _ modelSections: [CarPlaySection],
        dispatcher: Dispatcher,
        artwork: ArtworkSource
    ) -> [CPListSection] {
        modelSections.map { section in
            CPListSection(
                items: section.items.map { listItem($0, dispatcher: dispatcher, artwork: artwork) },
                header: section.header,
                sectionIndexTitle: nil
            )
        }
    }

    static func listItem(
        _ item: CarPlayItem,
        dispatcher: Dispatcher,
        artwork: ArtworkSource
    ) -> CPListItem {
        var detail = item.subtitle ?? ""
        if let extra = item.detailText, !extra.isEmpty {
            detail = detail.isEmpty ? extra : "\(detail) · \(extra)"
        }
        let listItem = CPListItem(text: item.title, detailText: detail.isEmpty ? nil : detail)
        listItem.isEnabled = item.isEnabled
        if let progress = item.progress {
            listItem.playbackProgress = CGFloat(progress)
        }

        switch item.accessory {
        case .none:
            break
        case .disclosure:
            listItem.accessoryType = .disclosureIndicator
        case .cloud:
            listItem.accessoryType = .cloud
        case .downloaded:
            listItem.setAccessoryImage(UIImage(systemName: "checkmark.circle.fill"))
        case .downloading(let fraction):
            listItem.setAccessoryImage(UIImage(systemName: downloadingSymbol(for: fraction)))
        case .nowPlaying:
            listItem.isPlaying = true
        }

        switch item.artwork {
        case .url(let url):
            // Symbol immediately, cover when the bytes arrive — never a blank row.
            listItem.setImage(UIImage(systemName: "headphones"))
            Task { @MainActor in
                if let image = await artwork.image(url) {
                    listItem.setImage(image)
                }
            }
        case .symbol(let name):
            listItem.setImage(UIImage(systemName: name))
        case .none:
            break
        }

        let action = item.action
        listItem.handler = { _, completion in
            Task { @MainActor in
                dispatcher.dispatch(action)
                completion()
            }
        }
        return listItem
    }

    private static func downloadingSymbol(for fraction: Double) -> String {
        switch fraction {
        case ..<0.25: return "arrow.down.circle"
        case ..<0.75: return "arrow.down.circle.dotted"
        default: return "arrow.down.circle.fill"
        }
    }
}
