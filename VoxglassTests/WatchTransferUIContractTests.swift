import Foundation
import Testing

/// Source-level guard: iPhone UI must route Watch transfers through the
/// shared confirmation/result helpers and never discard the transfer result.
/// The transport API in `PhoneAudioRelay.swift` and non-UI test doubles are
/// intentionally out of scope.
@Suite struct WatchTransferUIContractTests {
    private static let bookPage = "Voxglass/Features/Player/BookPageView.swift"
    private static let actionRow = "Voxglass/Features/Player/BookPageActionRow.swift"
    private static let overflow = "Voxglass/Features/Player/BookPageOverflowSheet.swift"
    private static let library = "Voxglass/Features/Library/LibraryView.swift"

    @Test func noUIFileDiscardsTransferResult() throws {
        for path in [Self.bookPage, Self.actionRow, Self.overflow, Self.library] {
            let text = try source(path)
            let discarded = text.range(
                of: #"_\s*=\s*await[^\n]*transferBookToWatch"#,
                options: .regularExpression
            ) != nil
            #expect(!discarded, "\(path) discards the result of transferBookToWatch")
        }
    }

    @Test func noFeatureFileDiscardsTransferResult() throws {
        let root = repositoryRoot().appendingPathComponent("Voxglass/Features")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                text.range(of: #"_\s*=\s*await[^\n]*transferBookToWatch"#, options: .regularExpression) == nil,
                "\(file.lastPathComponent) discards the result of transferBookToWatch"
            )
        }
    }

    @Test func overflowSheetNeverCallsTransportDirectly() throws {
        let text = try source(Self.overflow)
        #expect(!text.contains("transferBookToWatch("))
        #expect(text.contains("requestWatchDownload()"))
    }

    @Test func bookPageOwnsConfirmationsAndErrorBinding() throws {
        let text = try source(Self.bookPage)
        #expect(text.contains("\"Download to Apple Watch?\""))
        #expect(text.contains("Send to Apple Watch on cellular data?"))
        #expect(text.contains("case .needsCellularConfirmation"))
        #expect(text.contains("watchTransferErrorBinding"))
        #expect(text.contains("phoneAudioRelay.watchTransferError = message"))
    }

    @Test func libraryOwnsConfirmationsAndErrorBinding() throws {
        let text = try source(Self.library)
        #expect(text.contains("\"Download to Apple Watch?\""))
        #expect(text.contains("Send to Apple Watch on cellular data?"))
        #expect(text.contains("case .needsCellularConfirmation"))
        #expect(text.contains("watchTransferErrorBinding"))
        #expect(text.contains("phoneAudioRelay.watchTransferError = message"))
    }

    @Test func actionRowShowsPerBookPreparationState() throws {
        let text = try source(Self.actionRow)
        #expect(text.contains("watchPreparationByBook[book.book.id]"))
        #expect(text.contains("Preparing for Apple Watch"))
        #expect(text.contains(".accessibilityValue("))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
