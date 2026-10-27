import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Accessibility audit: keeps the identifiers the UI smoke tests key on from being
/// renamed silently, and checks that every identifier in the production surfaces
/// is well-formed (`area.segment.segment`, no spaces or underscores).
@Suite struct AccessibilityAuditTests {

    enum Area: String, CaseIterable {
        case iphone = "Voxglass/Features/Production"
        case phoneCarPlay = "Voxglass/App/CarPlay"
        case watch = "VoxglassWatch"
        case carPlay = "Voxglass/Core/CarPlay"
    }

    // MARK: - Sources under audit

    private static func sourceFiles(in directory: String) -> [String] {
        let areaURL = repositoryRoot().appendingPathComponent(directory)
        guard let enumerator = FileManager.default.enumerator(
            at: areaURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { url -> String? in
            guard let url = url as? URL, url.pathExtension == "swift" else { return nil }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func areaContains(_ area: Area, _ fragment: String) -> Bool {
        sourceFiles(in: area.rawValue).contains { $0.contains("\"\(fragment)") }
    }

    @Test func smokePathIdentifiersAreNeverRenamed() {
        // The exact identifiers the two UI smoke tests key on (§19.6). If a
        // view renames one of these, this test fails before the flaky UI run.
        let smokeKeys: [String: Area] = [
            "shelf.myProductions": .iphone, "detail.playWholeBook": .iphone, "detail.reviewFlagged": .iphone,
            "watch.library": .watch, "watch.nowPlaying": .watch
        ]
        let missing = smokeKeys.filter { !Self.areaContains($0.value, $0.key) }
        #expect(missing.isEmpty, "Smoke-path identifiers missing from source: \(missing.keys)")
    }

    @Test func identifiersAreWellFormed() {
        // Every identifier in the four production surfaces must be
        // dot-separated and free of spaces and underscores so accessibility
        // and XCUITest lookups behave. Registry identifiers use camelCase
        // segments (e.g. `settings.copyDiagnostics`), so mixed case is fine.
        let pattern = #/^[a-z][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)+$/#
        var offenders: [String] = []
        for area in Area.allCases {
            for source in Self.sourceFiles(in: area.rawValue) {
                for match in source.matchingStrings(of: #/"[a-z]+\.[a-zA-Z0-9.-]+"/#) {
                    let id = match.dropFirst().dropLast()
                    if id.wholeMatch(of: pattern) == nil {
                        offenders.append("\(area.rawValue): \(id)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Malformed accessibility identifiers: \(offenders)")
    }

    @Test func watchFieldConnectionAndPhoneOnlyDownloadControlsStayWired() {
        let phoneRelay = Self.sourceFiles(in: "Voxglass/App").joined(separator: "\n")
        let phoneViews = Self.sourceFiles(in: "Voxglass/Features").joined(separator: "\n")
        let watchSources = Self.sourceFiles(in: "VoxglassWatch").joined(separator: "\n")

        #expect(phoneRelay.contains("sessionWatchStateDidChange"))
        #expect(phoneRelay.contains("connectionToast = String(localized: \"Apple Watch connected\")"))
        #expect(phoneRelay.contains("kind: .librarySnapshot"))
        #expect(phoneViews.contains("\"nowplaying.watchDownload\""))
        #expect(phoneViews.contains("\"watchsync.connectionStatus\""))
        #expect(phoneViews.contains("\"watchsync.storageSummary\""))
        #expect(phoneViews.contains("\"watchsync.result\""))
        #expect(watchSources.contains("activationDidCompleteWith activationState"))
        #expect(!watchSources.contains("kind: .hello"))
        #expect(watchSources.contains("kind: .reconcileRequest"))
        #expect(watchSources.contains("WCSession.default.isReachable else"))
        #expect(watchSources.contains("receivedApplicationContext"))
        #expect(watchSources.contains("didReceiveUserInfo"))
        #expect(!watchSources.contains("requestedDownloadBookID"))
        #expect(!watchSources.contains("kind: .setBookDownload"))
        #expect(watchSources.contains("WatchPhonePushFiles.install(source: file.fileURL"))
        #expect(watchSources.contains("kind: .watchCatalog"))
    }
}

private extension String {
    func matchingStrings(of regex: Regex<Substring>) -> [Substring] {
        matches(of: regex).map(\.output)
    }
}
