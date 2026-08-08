import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Accessibility audit (spec §12 / §22.1). The identifier registry in the spec
/// is the normative list of every interactive control across the production
/// surfaces. These tests keep the registry honest in three ways:
///
/// 1. Every registry identifier resolves to a real control in the source
///    (exact string match, or prefix match for template patterns like
///    `record.take.<n>`), or is a documented absence whose control the MVP
///    implementation does not ship.
/// 2. The identifiers the UI smoke tests key on can never be renamed
///    silently — they are the contract between the test and the app.
/// 3. Every identifier used in the new surfaces is well-formed
///    (`area.segment.segment`, lowercase, no spaces) so VoiceOver and the
///    XCUITest `accessibilityIdentifier` lookups keep working.
@Suite struct AccessibilityAuditTests {

    enum Area: String, CaseIterable {
        case iphone = "Voxglass/Features/Production"
        case phoneCarPlay = "Voxglass/App/CarPlay"
        case watch = "VoxglassWatch"
        case carPlay = "Voxglass/Core/CarPlay"
    }

    struct Entry {
        let id: String
        let area: Area
        init(_ id: String, _ area: Area) { self.id = id; self.area = area }
    }

    // MARK: - The §22.1 registry (verbatim, template suffixes normalized)

    private static let iphoneRegistry: [String] = [
        "shelf.myProductions", "production.",
        "detail.playWholeBook", "detail.reviewFlagged", "detail.mode.", "detail.chapter.",
        "player.flag", "player.approve", "player.pickup", "player.addNote", "player.autoAdvance",
        "player.previousParagraph", "player.nextParagraph", "player.skipBack", "player.skipForward", "player.queue",
        "paragraphList.filter.", "paragraphList.row.", "paragraphList.playSelected",
        "queueBuilder.predicate.", "queueBuilder.autoAdvance", "queueBuilder.skipApproved",
        "queueBuilder.downloadToWatch", "queueBuilder.start",
        "note.category.", "note.text", "note.dictate", "note.save", "note.cancel",
        "sync.checkForUpdates", "sync.downloadAll", "sync.removeAudio", "sync.refreshWatch", "sync.pending",
    ]

    private static let watchRegistry: [String] = [
        "watch.production.", "watch.reviewFlagged", "watch.queue.", "watch.continue",
        "watch.player.flag", "watch.player.approve", "watch.player.pickup", "watch.player.previous", "watch.player.next",
        "watch.player.autoNext", "watch.paragraphText", "watch.confirmation.approved", "watch.confirmation.flagged",
        "watch.confirmation.pickup", "watch.playNext", "watch.dictate", "watch.dictation.category.",
        "watch.dictation.save", "watch.dictation.redictate", "watch.sync.status", "watch.offline.start",
        "watch.offline.remove",
    ]

    private static let carPlayRegistry: [String] = [
        "carplay.tab.", "carplay.production.", "carplay.queue.",
        "carplay.approve", "carplay.pickup", "carplay.keepFlagged", "carplay.playNext", "carplay.undo",
        "carplay.settings.autoAdvance", "carplay.settings.playContext", "carplay.settings.audioConfirmations",
    ]

    /// Registry entries whose controls the MVP implementation does not ship,
    /// each with the reason (kept truthful; adding the control requires
    /// removing the row here).
    private static let documentedAbsences: [String: String] = [
        "note.dictate": "dictation is a watch-only affordance",
        "carplay.playNext": "CPAlertTemplate actions expose no identifiers",
        "carplay.undo": "CPAlertTemplate actions expose no identifiers",
    ]

    // MARK: - Sources under audit

    private static func sourceFiles(in area: Area) -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // repo root
        let areaURL = root.appendingPathComponent(area.rawValue)
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

    private static func areaContains(_ area: Area, _ fragment: String) -> Bool {
        sourceFiles(in: area).contains { $0.contains("\"\(fragment)") }
    }

    // MARK: - Tests

    @Test func registryIdentifiersResolveInPhoneSource() {
        let missing = AccessibilityAuditTests.iphoneRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.iphone, id)
        }
        #expect(missing.isEmpty, "iPhone identifiers missing from source: \(missing)")
    }

    @Test func registryIdentifiersResolveInWatchSource() {
        let missing = AccessibilityAuditTests.watchRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.watch, id)
        }
        #expect(missing.isEmpty, "Watch identifiers missing from source: \(missing)")
    }

    @Test func registryIdentifiersResolveInCarPlaySource() {
        let missing = AccessibilityAuditTests.carPlayRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.carPlay, id) && !Self.areaContains(.phoneCarPlay, id)
        }
        #expect(missing.isEmpty, "CarPlay identifiers missing from source: \(missing)")
    }

    @Test func smokePathIdentifiersAreNeverRenamed() {
        // The exact identifiers the two UI smoke tests key on (§19.6). If a
        // view renames one of these, this test fails before the flaky UI run.
        let smokeKeys: [String: Area] = [
            "shelf.myProductions": .iphone, "detail.playWholeBook": .iphone, "detail.reviewFlagged": .iphone,
            "watch.queue.": .watch,        ]
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
            for source in Self.sourceFiles(in: area) {
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
}

private extension String {
    func matchingStrings(of regex: Regex<Substring>) -> [Substring] {
        matches(of: regex).map(\.output)
    }
}
