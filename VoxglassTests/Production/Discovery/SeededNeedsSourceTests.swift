import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct SeededNeedsSourceTests {

    @Test func bundledSeedMeetsTheFloor() async throws {
        let needs = try await SeededNeedsSource().fetch(using: StubFetcher().failAll(), clock: FixedClock())
        let short = needs.filter { $0.work.lengthClass == .short }
        let long = needs.filter { $0.work.lengthClass == .long }

        // G-18: the floor is ≥ 100 short and ≥ 20 long entries.
        #expect(short.count >= 100)
        #expect(long.count >= 20)

        // Every seed entry carries a non-unverified PD basis (curator-verified).
        for need in needs {
            #expect(need.provenance.pdBasis != .unverified)
            #expect(need.isSubmittable)
        }
        // IDs are unique (dedupe-safe).
        #expect(Set(needs.map(\.id)).count == needs.count)
    }

    @Test func seedHasExpectedFeaturedWork() async throws {
        let needs = try await SeededNeedsSource().fetch(using: StubFetcher().failAll(), clock: FixedClock())
        #expect(needs.contains { $0.work.title == "Hope is the thing with feathers" })
        #expect(needs.contains { $0.work.title == "Frankenstein" })
    }

    @Test func seedDecodeMatchesFixtureFormat() throws {
        let json = """
        { "version": 1, "entries": [
          { "title": "Fog", "author": "Carl Sandburg", "subject": "poem", "estSeconds": 30, "grade": "submittable" },
          { "title": "Draft", "author": "Someone", "subject": "poem", "estSeconds": 200, "grade": "practice" }
        ] }
        """
        let needs = try SeededNeedsSource().decode(Data(json.utf8), clock: FixedClock())
        #expect(needs.count == 2)
        #expect(needs[0].isSubmittable)
        #expect(needs[1].work.grade == .practice)
        #expect(needs[0].provenance.sources == [.seed])
    }
}
