import Testing
import Foundation
@testable import VoxglassCore

@MainActor
@Suite(.serialized) struct PlaybackCoordinatorSilenceTests {

    private func makeBook() -> BookWithChapters {
        let bookID = UUID()
        let ch = Chapter(
            bookID: bookID, title: "Ch 0", index: 0, duration: 100,
            localURL: URL(fileURLWithPath: "/tmp/\(bookID.uuidString)-0.mp3")
        )
        return BookWithChapters(book: Book(id: bookID, title: "Book", authors: ["A"], sourceID: UUID()), chapters: [ch])
    }

    private func makeCoordinator() -> (PlaybackCoordinator, FakeAudioEngine) {
        let db = AppDatabase.makeTemporaryDatabase(named: "silence-\(UUID().uuidString)")
        let engine = FakeAudioEngine()
        let coordinator = PlaybackCoordinator(engine: engine, positionStore: SQLitePositionStore(database: db))
        return (coordinator, engine)
    }

    @Test func silenceDetectedBoostsRate() async {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(1.0)
        engine.reset()

        engine.fireSilenceChanged(true)

        #expect(engine.calls.contains(.setRate(1.5)))  // At 1.0×, silence should boost to 1.5× (relative)
    }

    @Test func speechRestoresUserRate() async {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(1.5)
        engine.reset()

        engine.fireSilenceChanged(true)
        #expect(engine.calls.contains(.setRate(2.25)))  // At 1.5×, silence should boost to 2.25×

        engine.reset()
        engine.fireSilenceChanged(false)
        #expect(engine.calls.contains(.setRate(1.5)))  // Speech should restore user rate 1.5×
    }

    @Test func pauseResetsBoost() async {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        engine.fireSilenceChanged(true)
        #expect(engine.calls.contains(.setRate(1.5)))  // At 1.0×, silence should boost to 1.5×

        coordinator.pause()
        engine.reset()

        engine.fireSilenceChanged(true)
        #expect(engine.calls.contains(.setRate(1.5)))  // After pause, next silence should still trigger a fresh boost
    }

    @Test func manualRateChangeResetsBoost() async {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        engine.fireSilenceChanged(true)
        #expect(engine.calls.contains(.setRate(1.5)))

        engine.reset()
        coordinator.setPlaybackRate(2.0)

        engine.fireSilenceChanged(true)
        #expect(engine.calls.contains(.setRate(3.0)))  // At 2.0×, silence should boost to 3.0× (relative)
    }

    @Test func skipSilenceDisabledDoesNotBoost() async {
        UserDefaults.standard.set(false, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        UserDefaults.standard.synchronize()
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        engine.reset()

        engine.fireSilenceChanged(true)

        let rateCalls = engine.calls.filter {
            if case .setRate = $0 { return true }
            return false
        }
        #expect(rateCalls.isEmpty)  // When skip silence is disabled, no rate change should occur
    }

    @Test func maxRateDoesNotDropOnSilence() async {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(3.5)
        engine.reset()

        engine.fireSilenceChanged(true)

        #expect(engine.calls.contains(.setRate(3.5)))  // At 3.5×, silence boost must not drop the rate
    }

    @Test func highRateClampedToMax() async {
        UserDefaults.standard.set(true, forKey: AppPreferencesStore.Keys.skipSilenceEnabled)
        let (coordinator, engine) = makeCoordinator()
        await coordinator.play(makeBook())
        coordinator.setPlaybackRate(2.5)
        engine.reset()

        engine.fireSilenceChanged(true)

        #expect(engine.calls.contains(.setRate(3.5)))  // At 2.5×, 1.5× boost would be 3.75×, must clamp to 3.5×
    }
}
