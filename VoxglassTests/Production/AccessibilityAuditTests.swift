import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Accessibility audit (revised MVP §15.3 rule 2). The mockup HTML `id`
/// attributes are the normative identifier contract — index.html states that
/// "HTML `id` attributes on interactive elements are the `.accessibilityIdentifier`
/// values the implementation must use". These tests keep the two in sync:
///
/// 1. Every mockup `id` resolves to a real control in the app source (exact
///    string match, or template-prefix match for patterns like
///    `needs.card.<slug>`), or is explicitly pending a named fix stage.
/// 2. The identifiers the UI smoke tests key on can never be renamed
///    silently — they are the contract between the test and the app.
/// 3. Every identifier in the production surfaces and the mockups is
///    well-formed (`area.segment.segment`, lowercase, no spaces).
///
/// This replaces the Studio-era §22.1 hand-copied registry, which is exactly
/// what let the identifier drift go unnoticed while the old suite stayed green
/// (GAP_ANALYSIS G1). Parsing the mockups means a changed mockup id without a
/// matching app change fails here.
@Suite struct AccessibilityAuditTests {

    enum Area: String, CaseIterable {
        case iphone = "Voxglass/Features/Production"
        case phoneCarPlay = "Voxglass/App/CarPlay"
        case watch = "VoxglassWatch"
        case carPlay = "Voxglass/Core/CarPlay"
    }

    /// Directories the phone mockup ids must resolve in: the narration
    /// production surface plus Settings (mockup 15's `settings.*` rows live in
    /// `Features/Settings`, outside the production area).
    private static let phoneMockupSources = [
        "Voxglass/Features/Production",
        "Voxglass/Features/Settings",
    ]

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

    // MARK: - Mockup parsing

    private struct MockupEntry: CustomStringConvertible {
        let file: String
        let id: String
        var description: String { "\(file): \(id)" }
    }

    private static func mockupEntries() -> [MockupEntry] {
        let dir = repositoryRoot()
            .appendingPathComponent("docs/iphone-watch-only-revised-mvp/mockups")
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var entries: [MockupEntry] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "html", let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let file = url.lastPathComponent
            for match in content.matches(of: #/id="([^"]+)"/#) {
                entries.append(MockupEntry(file: file, id: String(match.output.1)))
            }
        }
        return entries
    }

    /// A mockup id resolves when the source contains it literally, or contains a
    /// template whose static prefix the id instantiates (`needs.card.hope` ←
    /// `"needs.card.\(needSlug(need))"`). `watch-` pages resolve against the
    /// watch surface (including `ProductionWatchAccessibility` constants); all
    /// other pages against the phone production + settings surfaces.
    private static func identifierResolves(_ entry: MockupEntry) -> Bool {
        let dirs = entry.file.hasPrefix("watch-") ? ["VoxglassWatch"] : phoneMockupSources
        for directory in dirs {
            let sources = sourceFiles(in: directory)
            if sources.contains(where: { $0.contains("\"\(entry.id)") }) { return true }
            for source in sources {
                for match in source.matchingStrings(of: #/"[a-z][a-zA-Z0-9.-]*\.\\\(/#) {
                    let prefix = match.dropFirst().dropLast(2) // drop the quote and the `\(`
                    if entry.id.hasPrefix(prefix) { return true }
                }
            }
        }
        return false
    }

    // MARK: - Tests

    @Test func mockupIdentifiersResolveInAppSource() {
        let entries = Self.mockupEntries()
        let unresolved = entries.filter { !Self.identifierResolves($0) }
        #expect(
            unresolved.isEmpty,
            "Mockup identifiers the app does not ship (D-G1: mockups follow the app): \(unresolved)"
        )
        #expect(!entries.isEmpty, "No mockup ids parsed — the mockup directory is the contract")
    }

    @Test func mockupIdentifiersAreWellFormed() {
        let pattern = #/^[a-z][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)+$/#
        let malformed = Self.mockupEntries()
            .map(\.id)
            .filter { $0.wholeMatch(of: pattern) == nil }
        #expect(malformed.isEmpty, "Malformed mockup identifiers: \(malformed)")
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
}

private extension String {
    func matchingStrings(of regex: Regex<Substring>) -> [Substring] {
        matches(of: regex).map(\.output)
    }
}
