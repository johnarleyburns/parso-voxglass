import Foundation
import Testing
@testable import VoxglassCore
@testable import VoxglassCoreTestSupport

@Suite struct ProjectionPolicyTests {

    private func take(origin: AudioOrigin) -> Take {
        Take(
            id: UUID(uuidString: "B40F5C4A-0000-0000-0000-000000000001")!,
            paragraphID: UUID(uuidString: "B40F5C4A-0000-0000-0000-000000000002")!,
            assetRef: AudioAssetReference(sha256: "sha", relativePath: "p.wav", byteCount: 1, contentType: "public.wav"),
            origin: origin,
            recordedAt: Date(timeIntervalSince1970: 0),
            duration: 1,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"),
            textHashAtRecording: "h"
        )
    }

    @Test func shouldProject_falseWhenHidden() {
        let policy = ProjectionPolicy()
        let project = ProjectFixtures.tiny()
        #expect(policy.shouldProject(project) == true)

        var hidden = project
        hidden.profile.isHiddenFromDevices = true
        #expect(policy.shouldProject(hidden) == false)
    }

    @Test func textIncludedOnlyWhenAllowed() {
        let paragraph = ProjectFixtures.tiny().allParagraphs[0]
        #expect(ProjectionPolicy(includeSourceText: true).text(for: paragraph) == paragraph.text)
        #expect(ProjectionPolicy(includeSourceText: false).text(for: paragraph) == nil)
    }

    @Test func originKind_mapsEveryOrigin() {
        let policy = ProjectionPolicy()
        #expect(policy.originKind(for: take(origin: .recorded)) == "recorded")
        #expect(policy.originKind(for: take(origin: .importedHuman(sourceFilename: "x.wav"))) == "importedHuman")
        #expect(policy.originKind(for: take(origin: .aiImported(providerLabel: "P"))) == "aiImported")
        #expect(policy.originKind(for: take(origin: .unknownImport(sourceFilename: "u.wav"))) == "unknownImport")
        #expect(policy.originKind(for: nil) == "none")
    }

    @Test func narrationOrigin_matchesEligibility() {
        let policy = ProjectionPolicy()
        #expect(policy.narrationOrigin(for: ProjectFixtures.tiny()) == .humanOnly)
        #expect(policy.narrationOrigin(for: ProjectFixtures.aiTainted()) == .containsImportedAI)
        #expect(policy.narrationOrigin(for: ProjectFixtures.aiUnselected()) == .humanOnly)
    }
}
