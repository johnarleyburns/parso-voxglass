import Foundation
import Observation
import VoxglassCore

/// The review player's state machine: queue position, transport, and every action
/// expressed as a `ReviewEvent` (device `.watch`) that the environment relays to the
/// phone. Haptics fire at paragraph boundaries; flag is the most prominent action.
@MainActor
@Observable
public final class WatchReviewModel {

    public enum Confirmation: Sendable {
        case approved
        case flagged
        case needsPickup
    }

    public let payload: ResolvedQueuePayload
    public var currentIndex = 0
    public var autoAdvance: Bool
    public var confirmation: Confirmation?
    public var isAudioAvailable = true

    private let environment: ProductionWatchEnvironment

    public init(
        payload: ResolvedQueuePayload,
        environment: ProductionWatchEnvironment
    ) {
        self.payload = payload
        self.environment = environment
        self.autoAdvance = payload.autoAdvance
    }

    public var count: Int { payload.paragraphIDs.count }
    public var positionLabel: String { "\(min(currentIndex + 1, count))/\(count)" }

    public var currentParagraphID: UUID? {
        guard payload.paragraphIDs.indices.contains(currentIndex) else { return nil }
        return payload.paragraphIDs[currentIndex]
    }

    public var currentText: String? {
        currentParagraphID.flatMap { payload.texts[$0] }
    }

    public var currentNote: String? {
        currentParagraphID.flatMap { payload.notes[$0] }
    }

    public var currentChapterLabel: String? {
        currentParagraphID.flatMap { payload.chapterLabels[$0] }
    }

    public var currentDuration: TimeInterval? {
        currentParagraphID.flatMap { payload.durations[$0] }
    }

    public var currentTag: ReviewTag? {
        currentParagraphID.flatMap { payload.tags[$0] }
    }

    public func playCurrent() async {
        guard let id = currentParagraphID else { return }
        if let url = environment.audioStore.localURL(for: id) {
            isAudioAvailable = true
            environment.player.load(url: url, paragraphID: id)
            environment.player.play()
        } else if !environment.transport.isReachable {
            // Explicit offline state: no audio and the phone is unreachable.
            isAudioAvailable = false
            environment.player.stop()
        }
        // Audio not yet downloaded but the phone is reachable — it may still arrive.
    }

    public func previous() async {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        await playCurrent()
    }

    public func next() async {
        guard currentIndex + 1 < count else { return }
        currentIndex += 1
        await playCurrent()
    }

    public func flag() async {
        await emit(.flag)
        confirmation = .flagged
    }

    public func approve() async {
        await emit(.approve)
        confirmation = .approved
    }

    public func needsPickup() async {
        await emit(.needsPickup)
        confirmation = .needsPickup
    }

    /// No event — keeps the current flag and advances.
    public func keepFlaggedAndContinue() async {
        if autoAdvance { await next() }
    }

    public func dismissConfirmation() {
        confirmation = nil
    }

    public func playNext() async {
        confirmation = nil
        await playCurrent()
    }

    public func addNote(_ text: String, tag: ReviewTag?) async {
        await emit(.addNote, noteText: text, tag: tag)
    }

    public func requestVoiceNote() async {
        await emit(.voiceNoteRequested, noteText: nil)
    }

    private func emit(_ type: ReviewEventType, noteText: String? = nil, tag: ReviewTag? = nil) async {
        guard let id = currentParagraphID else { return }
        let event = ReviewEvent(
            projectID: payload.projectID,
            paragraphID: id,
            type: type,
            noteText: noteText,
            tag: tag,
            device: .watch
        )
        await environment.sendEvent(event)
        if autoAdvance {
            await next()
        }
    }
}
