import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct OpenLibriVoxReaderRequestTests {
    private let now = NeedsDiscoveryConstants.seedFirstSeen

    @Test func onlyActiveVerifiedLibriVoxReaderRequestsQualify() {
        #expect(request().isOpenLibriVoxReaderRequest(at: now))
        #expect(request(signal: .weeklyFeatured).isOpenLibriVoxReaderRequest(at: now))
        #expect(!request(grade: .practice).isOpenLibriVoxReaderRequest(at: now))
        #expect(!request(basis: .unverified).isOpenLibriVoxReaderRequest(at: now))
        for signal in [NeedSignal.evergreen, .catalogGap, .proofListenerNeeded] {
            #expect(!request(signal: signal).isOpenLibriVoxReaderRequest(at: now))
        }
        #expect(!request(expiresAt: now).isOpenLibriVoxReaderRequest(at: now))
        #expect(request(expiresAt: now.addingTimeInterval(60)).isOpenLibriVoxReaderRequest(at: now))
    }

    @Test func samplesAndCatalogRowsCannotMasqueradeAsOpenProjects() {
        #expect(!makeNeed(title: "Starter poem", text: "sample").isOpenLibriVoxReaderRequest(at: now))
        for thread in [
            "https://gutenberg.org/ebooks/1",
            "https://forum.librivox.org.example.com/viewtopic.php?t=123",
            "https://forum.librivox.org/viewforum.php?f=19",
            "https://forum.librivox.org/viewtopic.php",
            "https://forum.librivox.org/viewtopic.php?t=0",
            "https://forum.librivox.org/viewtopic.php?t=practice"
        ] {
            #expect(!request(thread: thread).isOpenLibriVoxReaderRequest(at: now))
        }
        #expect(!request(thread: nil).isOpenLibriVoxReaderRequest(at: now))
    }

    @Test func textlessRealProjectsRemainAvailableForCoordinatorLinks() {
        let need = request()
        #expect(need.isOpenLibriVoxReaderRequest(at: now))
        #expect(!need.recordableOniOS)
    }

    private func request(
        signal: NeedSignal = .openProjectNeedsReader,
        grade: WorkGrade = .submittable,
        basis: PDBasis = .curatorVerified,
        thread: String? = "https://forum.librivox.org/viewtopic.php?t=123",
        expiresAt: Date? = nil
    ) -> NarrationNeed {
        NarrationNeed(
            work: NarratableWork(title: "Real book", author: "Author", grade: grade),
            signal: signal,
            strength: 95,
            provenance: NeedProvenance(
                sources: [.snapshot], firstSeen: now, lastConfirmed: now,
                pdBasis: basis, libriVoxThreadURL: thread.flatMap(URL.init(string:))
            ),
            expiresAt: expiresAt
        )
    }
}
