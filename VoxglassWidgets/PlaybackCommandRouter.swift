import Foundation

/// The widget extension never owns playback state. The shared intent is
/// executed by the app process; this symbol exists only for target wiring.
enum PlaybackCommandRouter {
    static func perform(_ command: PlaybackCommand) async throws {}
}
