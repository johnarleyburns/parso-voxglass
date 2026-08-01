import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct DomainCodingTests {

    @Test func roundTripsAudiobookProject() throws {
        let project = ProjectFixtures.tiny()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(project)
        let decoded = try decoder.decode(AudiobookProject.self, from: data)
        #expect(decoded.id == project.id)
        #expect(decoded.chapters.count == project.chapters.count)
        #expect(decoded.allParagraphs.count == project.allParagraphs.count)
    }

    @Test func roundTripsAudioOriginAllCasesFromJSON() throws {
        let cases: [(AudioOrigin, String)] = [
            (.recorded, #"{"kind":"recorded"}"#),
            (.importedHuman(sourceFilename: "test.wav"), #"{"kind":"importedHuman","payload":"test.wav"}"#),
            (.aiImported(providerLabel: "ElevenLabs"), #"{"kind":"aiImported","payload":"ElevenLabs"}"#),
            (.unknownImport(sourceFilename: "mystery.mp3"), #"{"kind":"unknownImport","payload":"mystery.mp3"}"#),
        ]

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for (origin, json) in cases {
            let decoded = try decoder.decode(AudioOrigin.self, from: Data(json.utf8))
            #expect(decoded == origin)

            let reencoded = try encoder.encode(origin)
            let redecoded = try decoder.decode(AudioOrigin.self, from: reencoded)
            #expect(redecoded == origin)
        }
    }

    @Test func roundTripsAudioOriginViaFlatStorage() throws {
        let cases: [AudioOrigin] = [
            .recorded,
            .importedHuman(sourceFilename: "test.wav"),
            .aiImported(providerLabel: "ElevenLabs"),
            .unknownImport(sourceFilename: "mystery.mp3"),
        ]

        for origin in cases {
            let kind = origin.storageKind
            let payload = origin.storagePayload
            let recovered = try AudioOrigin(storageKind: kind, storagePayload: payload)
            #expect(recovered == origin)
        }
    }

    @Test func audioOriginIsHumanNarration() {
        #expect(AudioOrigin.recorded.isHumanNarration == true)
        #expect(AudioOrigin.importedHuman(sourceFilename: "f").isHumanNarration == true)
        #expect(AudioOrigin.aiImported(providerLabel: "p").isHumanNarration == false)
        #expect(AudioOrigin.unknownImport(sourceFilename: "f").isHumanNarration == false)
    }

    @Test func roundTripsReviewEvent() throws {
        let event = ReviewEvent(
            projectID: UUID(),
            paragraphID: UUID(),
            type: .flag,
            noteText: "test note",
            tag: .misread,
            device: .iPhone
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(ReviewEvent.self, from: data)
        #expect(decoded.id == event.id)
        #expect(decoded.type == .flag)
        #expect(decoded.noteText == "test note")
        #expect(decoded.tag == .misread)
        #expect(decoded.device == .iPhone)
    }

    @Test func roundTripsDestinationProfile() throws {
        let profile = DestinationProfile.librivox
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(DestinationProfile.self, from: data)
        #expect(decoded.id == .librivox)
        #expect(decoded.tier == .free)
    }

    @Test func buildStressFixture() {
        let project = ProjectFixtures.stress(paragraphs: 10_000)
        #expect(project.allParagraphs.count == 10_000)
        #expect(project.totalCount == 10_000)
    }

    @Test func stressRoundTrip() throws {
        let project = ProjectFixtures.stress(paragraphs: 10_000)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(project)
        let decoded = try decoder.decode(AudiobookProject.self, from: data)
        #expect(decoded.allParagraphs.count == 10_000)
    }
}
