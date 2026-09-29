import ActivityKit
import SwiftUI
import WidgetKit

struct BookLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("VOXGLASS · CH \(context.state.chapterIndex) OF \(context.state.chapterCount)")
                    .font(.caption2.weight(.semibold))
                Text(context.attributes.title).font(.headline).lineLimit(1)
                Text(context.state.chapterTitle).font(.caption).lineLimit(1)
                if let interval = context.state.progressStart.flatMap({ start in context.state.progressEnd.map { start...$0 } }) {
                    ProgressView(timerInterval: interval, countsDown: false)
                } else {
                    ProgressView(value: context.state.chapterFraction)
                }
                HStack {
                    Button(intent: SkipBackwardIntent()) { Image(systemName: "gobackward.15") }
                        .accessibilityLabel("Skip back 15 seconds")
                    Button(intent: TogglePlaybackIntent()) { Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(context.state.isPlaying ? "Pause" : "Play") // l10n-exempt: state-dependent accessibility or status copy
                    Button(intent: SkipForwardIntent()) { Image(systemName: "goforward.30") }
                        .accessibilityLabel("Skip forward 30 seconds")
                }
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.04, green: 0.04, blue: 0.05))
            .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack { Text(context.attributes.title).lineLimit(1); Text(context.state.chapterTitle).font(.caption) }
                }
                DynamicIslandExpandedRegion(.bottom) { ProgressView(value: context.state.chapterFraction) }
            } compactLeading: {
                Image(systemName: "headphones.circle.fill")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
            } minimal: {
                Image(systemName: "waveform")
            }
        }
    }
}
