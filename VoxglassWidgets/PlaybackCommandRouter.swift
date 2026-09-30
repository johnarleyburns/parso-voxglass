import Foundation
import VoxglassCore

/// The widget extension never owns playback state. The shared intent is
/// executed by the app process; this symbol exists only for target wiring.
enum PlaybackCommandRouter {
    static func perform(_ command: PlaybackCommand) async throws {
        let widgetCommand: WidgetPlaybackCommandStore.Command
        switch command {
        case .resume: widgetCommand = .resume
        case .togglePlayPause: widgetCommand = .togglePlayPause
        case .skipBackward: widgetCommand = .skipBackward
        case .skipForward: widgetCommand = .skipForward
        case .cycleSleepTimer:
            return
        }
        WidgetPlaybackCommandStore.request(widgetCommand)
    }
}
