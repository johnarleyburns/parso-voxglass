import Testing
import VoxglassCore

@Suite struct DestinationRequirementsTests {
    @Test func personalRequiresOnlyTitleAndNoRightsAttestation() {
        #expect(DestinationProfile.profile(for: .personalMaster).requiredMetadata == [.title])
        #expect(!DestinationProfile.requiresRightsAttestation(.personalMaster))
    }

    @Test func publicAndRetailDestinationsRequireRightsAttestation() {
        for destination in DestinationID.allCases where destination != .personalMaster {
            #expect(DestinationProfile.requiresRightsAttestation(destination))
        }
        #expect(DestinationProfile.librivox.requiredMetadata.contains(.narrator))
        #expect(DestinationProfile.librivox.requiredMetadata.contains(.sourceURL))
    }
}
