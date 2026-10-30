import Foundation
import Testing
@testable import VoxglassCore

@Suite struct BookPageUnificationTests {
    @Test func legacyDetailAndNowPlayingViewsAreGone() throws {
        let files = try swiftFiles(under: repoRoot.appendingPathComponent("Voxglass"))

        for file in files {
            let text = try String(contentsOf: file)
            let path = relativePath(file)
            #expect(!(text.contains("struct NowPlayingView")))  // \(path) should not contain struct NowPlayingView
            #expect(!(text.contains("struct BookDetailView")))  // \(path) should not contain struct BookDetailView
            #expect(!(text.contains("BookDetailView(book:")))  // \(path) should not contain BookDetailView(book:
        }
    }

    @Test func explicitBookSelectionsRouteThroughSelectAndPlay() throws {
        let paths = [
            "Voxglass/Features/Player/BookPageView.swift",
            "Voxglass/Features/Listen/ListenView.swift",
            "Voxglass/Features/Library/LibraryView.swift",
            "Voxglass/Features/Library/PlaylistsView.swift",
            "Voxglass/Features/Library/BookRelatedViews.swift"
        ]
        for path in paths {
            let text = try source(path)
            #expect(!text.contains("await playback.play("))  // \(path) must use selectAndPlay for book selections
            #expect(text.contains("playback.selectAndPlay("))
        }
        let page = try source("Voxglass/Features/Player/BookPageView.swift")
        #expect(page.contains("playback.selectAndPlay(resolved, chapter: chapter)"))
        #expect(page.contains("await playback.seek(to: 0)"))
    }

    @Test func bookPageKeepsAccessibilityIdentifiers() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")
        let overflow = try source("Voxglass/Features/Player/BookPageOverflowSheet.swift")

        let identifiers = [
            "nowplaying.speed",
            "nowplaying.sleepTimer",
            "nowplaying.bookmark",
            "nowplaying.download",
            "nowplaying.watchDownload",
            "nowplaying.eq"
        ]

        for id in identifiers {
            let found = page.contains(id) || actionRow.contains(id) || overflow.contains(id)
            #expect(found)  // \(id) must be present in BookPageView, BookPageActionRow, or BookPageOverflowSheet
        }
    }

    @Test func bookPageExposesAirPlay() throws {
        let button = try source("Voxglass/Features/Player/RoutePickerButton.swift")
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")

        #expect(button.contains("AVRoutePickerView"))  // RoutePickerButton must wrap AVRoutePickerView
        #expect(actionRow.contains("RoutePickerButton"))  // Action row must reference RoutePickerButton
    }

    @Test func actionRowUsesIconsNotFullWidthButtons() throws {
        let actionRow = try source("Voxglass/Features/Player/BookPageActionRow.swift")

        #expect(!(actionRow.contains("SecondaryActionButton")))  // Action row must not contain SecondaryActionButton
        #expect(!(actionRow.contains("PrimaryActionButton")))  // Action row must not contain PrimaryActionButton
        #expect(!(actionRow.contains(".frame(height: 46)")))  // Action row must not use 46pt button height
    }

    @Test func descriptionIsClampedWithShowMore() throws {
        let page = try source("Voxglass/Features/Player/BookPageView.swift")

        #expect(page.contains("lineLimit(isDescriptionExpanded ? nil : 1)"))  // Description must be clamped with show more
        #expect(page.contains("Show more"))  // BookPageView must contain Show more
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath))
    }

    private func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var result: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                result.append(file)
            }
        }
        return result
    }

    private func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
    }
}

@Suite struct BookPageWatchDownloadContractTests {
    private func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path))
    }

    @Test func overflowAndActionRowNeverCallTransport() throws {
        let overflow = try read("Voxglass/Features/Player/BookPageOverflowSheet.swift")
        let row = try read("Voxglass/Features/Player/BookPageActionRow.swift")
        #expect(overflow.contains("requestWatchDownload()"))
        #expect(!overflow.contains("transferBookToWatch("))
        #expect(!row.contains("transferBookToWatch("))
        #expect(row.contains("requestWatchDownload()"))
        #expect(row.contains("nowplaying.watchDownload"))
    }

    @Test func bookPageViewOwnsConfirmationsAndSingleHelper() throws {
        let page = try read("Voxglass/Features/Player/BookPageView.swift")
        #expect(page.components(separatedBy: "transferBookToWatch(").count == 2)
        #expect(page.contains("private func submitWatchTransfer(_ book: BookWithChapters, allowCellular: Bool) async"))
        #expect(page.contains("case .started:"))
        #expect(page.contains("case .needsCellularConfirmation:"))
        #expect(page.contains("case .failed(let message):"))
        #expect(page.contains("\"Download to Apple Watch?\""))
        #expect(page.contains("submitWatchTransfer(book, allowCellular: true)"))
        #expect(page.contains("Couldn't Send to Apple Watch"))
        #expect(page.components(separatedBy: "requestWatchDownload: { requestWatchDownload() }").count == 3)
    }
}

@Suite struct WatchPreparationProgressContractTests {
    private func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path))
    }

    @Test func relayPublishesPerBookPreparationBeforeAwaitingDownload() throws {
        let relay = try read("Voxglass/App/PhoneAudioRelay.swift")
        #expect(relay.contains("case downloadingOnPhone(progress: Double)"))
        #expect(relay.contains("case preparingAudio"))
        #expect(relay.contains("watchPreparationByBook: [UUID: PhoneWatchPreparationState]"))
        let start = try #require(relay.range(of: "watchPreparationByBook[book.book.id] = .downloadingOnPhone(progress: 0)"))
        let await_ = try #require(relay.range(of: "await offlineManager.makeAvailableOffline("))
        #expect(start.lowerBound < await_.lowerBound)
        #expect(relay.contains("watchPreparationByBook[book.book.id] = .downloadingOnPhone(progress: min(max(progress, 0), 1))"))
        #expect(relay.contains("watchPreparationByBook[book.book.id] = .preparingAudio"))
        // Cleared on every exit (success, failure, cancellation) and only for the selected book.
        #expect(relay.contains("watchPreparationByBook[preparingBookID] = nil"))
        #expect(!relay.contains("watchPreparationByBook = [:]"))
    }

    @Test func localBookSkipsPhoneDownloadState() throws {
        let relay = try read("Voxglass/App/PhoneAudioRelay.swift")
        let guardRange = try #require(relay.range(of: "if needsPhoneDownload, offlineManager.state(for: book.book.id) != .cached {"))
        let download = try #require(relay.range(of: ".downloadingOnPhone(progress: 0)"))
        #expect(guardRange.lowerBound < download.lowerBound)
    }

    @Test func actionRowRendersBothPreparationStatesForSelectedBookOnly() throws {
        let row = try read("Voxglass/Features/Player/BookPageActionRow.swift")
        #expect(row.contains("phoneAudioRelay.watchPreparationByBook[book.book.id]"))
        #expect(row.contains("case .downloadingOnPhone(let progress):"))
        #expect(row.contains("\"Preparing for Apple Watch, "))
        #expect(row.contains("percent"))
        #expect(row.contains("case .preparingAudio:"))
        #expect(row.contains("\"Preparing audio for Apple Watch\""))
        #expect(row.contains("watchTransferButton"))
    }
}
