import XCTest
@testable import VoxglassCore

/// Paywall ↔ enforcement drift guards (P1). `ProPaywallView` lives in the app
/// target, so these parse the source the same way `guard_wiring.sh` Rule 4
/// does — in-process, from the repo tree — keeping the advertised bullets, the
/// `ProFeature` enum, and the Settings count string in lockstep.
final class ProPaywallContentTests: XCTestCase {

    func testAdvertisedFeaturesMatchEveryProFeatureCase() throws {
        let advertised = try advertisedFeatureNames()
        let expected = Set(ProFeature.allCases.map(\.rawValue))

        XCTAssertEqual(advertised.count, 8, "the paywall must advertise exactly 8 Pro features")
        XCTAssertEqual(Set(advertised), expected, "every ProFeature case must be advertised on the paywall")
        XCTAssertEqual(advertised.count, Set(advertised).count, "no feature may be advertised twice")
    }

    func testEveryAdvertisedFeatureHasARealEnforcementGate() throws {
        let advertised = try advertisedFeatureNames()
        var ungated: [String] = []
        let sources = try appSourceContents()

        for feature in advertised {
            let gate = "ProFeature.isEnabled(.\(feature))"
            if !sources.contains(where: { $0.contents.contains(gate) }) {
                ungated.append(feature)
            }
        }

        XCTAssertTrue(
            ungated.isEmpty,
            "advertised features without a ProFeature.isEnabled(_:) gate: \(ungated.joined(separator: ", "))"
        )
    }

    func testSettingsProFeatureCountDerivesFromAdvertisedArray() throws {
        let settings = try String(
            contentsOf: sourcesRoot()
                .appendingPathComponent("Features/Settings/SettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            settings.contains("ProPaywallView.advertised.count"),
            "the Settings Pro row must derive its feature count from ProPaywallView.advertised"
        )
        XCTAssertNil(
            settings.range(of: #"unlock \d+ Pro features"#, options: .regularExpression),
            "the Settings Pro row must not hardcode the Pro feature count"
        )
    }

    // MARK: - Source parsing

    private func advertisedFeatureNames() throws -> [String] {
        let paywall = try String(
            contentsOf: sourcesRoot()
                .appendingPathComponent("Features/Settings/ProPaywallView.swift"),
            encoding: .utf8
        )
        let pattern = #"feature:\s*\.([a-zA-Z_][a-zA-Z0-9_]*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(paywall.startIndex..., in: paywall)
        return regex.matches(in: paywall, range: range).compactMap { match in
            Range(match.range(at: 1), in: paywall).map { String(paywall[$0]) }
        }
    }

    private func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Voxglass")
    }

    private func appSourceContents() throws -> [(file: String, contents: String)] {
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var sources: [(file: String, contents: String)] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            sources.append((fileURL.lastPathComponent, contents))
        }
        return sources
    }
}
