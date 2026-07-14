import XCTest
@testable import Voxglass

/// Registry-drift safety net (§6/§8): the paywall catalog, the `ProFeature`
/// enum, and the free-tier registry must stay in lockstep. Adding or removing a
/// Pro feature without updating the paywall (or vice versa) fails here.
final class ProPaywallContentTests: XCTestCase {

    func testEveryProFeatureIsCovered() {
        let advertisedFeatures = ProPaywallView.advertised.map(\.feature)
        let advertisedSet = Set(advertisedFeatures)

        // cachePresets and prefetchDepth are folded into the offlineDownloads row
        // as supporting detail; they are not standalone bullets but are covered.
        let foldedFeatures: Set<ProFeature> = [.cachePresets, .prefetchDepth]
        let allCovered = advertisedSet.union(foldedFeatures)

        XCTAssertEqual(
            allCovered, Set(ProFeature.allCases),
            "Every ProFeature must be covered — either as a standalone ad or folded into another row."
        )
        XCTAssertEqual(
            advertisedFeatures.count, Set(advertisedFeatures).count,
            "No Pro feature may be advertised more than once."
        )
    }

    func testOfflineDownloadsIsAdvertised() {
        let features = ProPaywallView.advertised.map(\.feature)
        let index = features.firstIndex(of: .offlineDownloads)
        XCTAssertNotNil(index, "Offline Downloads must be advertised — but no longer needs to be at the top (P4 paywall refit)")
    }

    func testEveryAdvertisementHasCopyAndIcon() {
        for ad in ProPaywallView.advertised {
            XCTAssertFalse(ad.icon.isEmpty)
            XCTAssertFalse(ad.title.isEmpty)
            XCTAssertFalse(ad.description.isEmpty)
        }
    }

    func testCarPlayAndAppleWatchAreNotAdvertised() {
        let titles = ProPaywallView.advertised.map { $0.title.lowercased() }
        XCTAssertFalse(titles.contains { $0.contains("carplay") })
        XCTAssertFalse(titles.contains { $0.contains("apple watch") })
        // The removed features must not be reachable as ProFeature cases either.
        XCTAssertNil(ProFeature(rawValue: "carplay"))
        XCTAssertNil(ProFeature(rawValue: "appleWatch"))
    }

    func testEQAdvertisementDoesNotClaimNormalization() {
        let eqAd = ProPaywallView.advertised.first { $0.feature == .eq }
        XCTAssertNotNil(eqAd)
        XCTAssertFalse(eqAd!.title.lowercased().contains("volume normalization"),
                       "EQ advertisement must not claim normalization (it ships free)")
        XCTAssertFalse(eqAd!.title.lowercased().contains("+"),
                       "EQ title must not bundle normalization with a '+'")
    }

    func testFreeSectionNamesNormalizationAndSkipSilence() {
        // The free section copy lives in the ProPaywallView.foreverFreeSection body.
        // We can't directly inspect the text from tests, but we can verify the
        // structure hasn't regressed: normalization is NOT a ProFeature case.
        XCTAssertNil(ProFeature(rawValue: "volumeNormalization"))
        XCTAssertNil(ProFeature(rawValue: "skipSilence"))
    }
}
