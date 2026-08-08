import Foundation
import Testing
import VoxglassCore

/// Route-readiness classification (spec §7.1). Thresholds come from the ACX
/// `DestinationProfile`; the classifier must match mockup 06b's transport
/// mapping (USB → retail, wired headset → community, built-in → community,
/// Bluetooth → draft) and downgrade on failed measurements.
@Suite struct CaptureRouteClassifierTests {

    private func route(
        transports: Set<CapturePortTransport> = [.usb],
        stable: Bool = true,
        latency: TimeInterval = 0.01,
        noiseFloor: Double? = nil,
        peak: Double? = nil,
        speechRMS: Double? = nil
    ) -> CaptureRouteInfo {
        CaptureRouteInfo(
            transports: transports,
            sampleRate: 48_000,
            isSampleRateStable: stable,
            inputLatencySeconds: latency,
            measuredNoiseFloorDBFS: noiseFloor,
            measuredPeakDBFS: peak,
            measuredSpeechRMSDBFS: speechRMS
        )
    }

    @Test func usbRouteIsRetailReady() {
        #expect(CaptureRouteClassifier.classify(route()) == .retailReady)
    }

    @Test func passingRoomTestKeepsUsbRetailReady() {
        // Mockup 06b: noise -64.2, peak -8.4, speech -19.6 -> retail-ready.
        let info = route(noiseFloor: -64.2, peak: -8.4, speechRMS: -19.6)
        #expect(CaptureRouteClassifier.classify(info) == .retailReady)
    }

    @Test func wiredHeadsetIsCommunityReady() {
        #expect(CaptureRouteClassifier.classify(route(transports: [.wiredHeadset])) == .communityReady)
    }

    @Test func builtInMicIsCommunityReady() {
        // Mockup 06b: built-in iPhone mic is "Community", not draft.
        #expect(CaptureRouteClassifier.classify(route(transports: [.builtIn])) == .communityReady)
    }

    @Test func bluetoothIsDraftOnlyAndNeverBlocked() {
        // §7.1: Bluetooth MUST NOT be blocked — the classifier only labels it.
        #expect(CaptureRouteClassifier.classify(route(transports: [.bluetooth])) == .draftOnly)
    }

    @Test func airPlayAndUnknownFallBackToCommunity() {
        #expect(CaptureRouteClassifier.classify(route(transports: [.airPlay])) == .communityReady)
        #expect(CaptureRouteClassifier.classify(route(transports: [.other])) == .communityReady)
    }

    @Test func failedNoiseFloorTargetDowngradesToDraft() {
        let info = route(noiseFloor: -45)
        #expect(CaptureRouteClassifier.classify(info) == .draftOnly)
    }

    @Test func highLatencyDowngradesToDraft() {
        let info = route(latency: 0.25)
        #expect(CaptureRouteClassifier.classify(info) == .draftOnly)
    }

    @Test func unstableSampleRateDowngradesRetailToCommunity() {
        let info = route(stable: false)
        #expect(CaptureRouteClassifier.classify(info) == .communityReady)
    }

    @Test func unstableSampleRateDoesNotRecoverDraft() {
        let info = route(transports: [.bluetooth], stable: false)
        #expect(CaptureRouteClassifier.classify(info) == .draftOnly)
    }

    @Test func clippingPeakInRoomTestDowngradesToCommunity() {
        let info = route(peak: -1.0)
        #expect(CaptureRouteClassifier.classify(info) == .communityReady)
    }

    @Test func speechRmsOutsideRetailBandDowngradesToCommunity() {
        let info = route(speechRMS: -10)
        #expect(CaptureRouteClassifier.classify(info) == .communityReady)
    }

    @Test func labelsMatchUserFacingStrings() {
        #expect(CaptureRouteClassifier.label(for: .retailReady) == "Retail-ready")
        #expect(CaptureRouteClassifier.label(for: .communityReady) == "Community-ready")
        #expect(CaptureRouteClassifier.label(for: .draftOnly) == "Draft only")
    }

    @Test func severityRankOrdersDraftAsWorst() {
        #expect(CaptureRouteClass.retailReady.severityRank < CaptureRouteClass.communityReady.severityRank)
        #expect(CaptureRouteClass.communityReady.severityRank < CaptureRouteClass.draftOnly.severityRank)
    }
}
