import Foundation

@MainActor
protocol AudioEngine: AnyObject {
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var isPlaying: Bool { get }
    var onPlaybackEnded: (@MainActor () -> Void)? { get set }

    func configureAudioSession()
    func load(url: URL, startTime: TimeInterval) async throws
    func play()
    func pause()
    func seek(to position: TimeInterval) async
}

enum AudioEngineError: Error, LocalizedError {
    case missingPlayableURL

    var errorDescription: String? {
        switch self {
        case .missingPlayableURL:
            "This chapter does not have a playable audio URL."
        }
    }
}

