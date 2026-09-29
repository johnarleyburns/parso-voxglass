import Foundation

/// A playback command issued from outside the app UI.
public enum PlaybackCommand: String, Codable, Sendable {
    case resume
    case togglePlayPause
    case skipBackward
    case skipForward
    case cycleSleepTimer
}
