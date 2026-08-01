import Foundation

public protocol SegmentPlayer: AnyObject, Sendable {
    var currentParagraphID: UUID? { get }
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    var events: AsyncStream<PlayerEvent> { get }

    func load(_ segments: [PlaybackSegment]) async throws
    func play() async throws
    func pause() async
    func seek(toParagraph id: UUID, offset: TimeInterval) async throws
    func nextParagraph() async throws
    func previousParagraph() async throws
    func skip(by seconds: TimeInterval) async throws
    func setRate(_ rate: Float) async
}

public enum PlayerEvent: Sendable, Equatable {
    case paragraphChanged(UUID)
    case finished
    case stalled
    case failed(String)
    case bufferedThrough(UUID)
}
