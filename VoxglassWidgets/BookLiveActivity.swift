import ActivityKit
import SwiftUI
import WidgetKit

struct BookLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookActivityAttributes.self) { context in
            // Keep the activity out of the Lock Screen layout. The Dynamic
            // Island and Watch live surfaces still get the active content.
            EmptyView()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack { Text(context.attributes.title).lineLimit(1); Text(context.state.chapterTitle).font(.caption) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.chapterFraction)
                        HStack {
                            Button(intent: SkipBackwardIntent()) { Image(systemName: "gobackward.15") }
                            Button(intent: TogglePlaybackIntent()) { Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill") }
                            Button(intent: SkipForwardIntent()) { Image(systemName: "goforward.30") }
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "headphones.circle.fill")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
            } minimal: {
                Image(systemName: "waveform")
            }
            .widgetURL(URL(string: "voxglass://book/\(context.attributes.bookID.uuidString)"))
        }
    }
}
