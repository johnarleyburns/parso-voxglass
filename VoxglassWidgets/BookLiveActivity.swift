import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

private let liveActivityPauseLabel = String(localized: "Pause")
private let liveActivityPlayLabel = String(localized: "Play")

struct BookLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookActivityAttributes.self) { context in
            // Keep the activity out of the Lock Screen layout. The Dynamic
            // Island and Watch live surfaces still get the active content.
            EmptyView()
        } dynamicIsland: { context in
            let rateText = context.state.rate.formatted(.number.precision(.fractionLength(1)))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    cover(for: context, size: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).lineLimit(1).widgetAccentable()
                        Text("Chapter \(context.state.chapterIndex) of \(context.state.chapterCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(context.state.chapterTitle).font(.caption).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(rateText)×")
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel("Playback speed \(rateText) times")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: context.state.chapterFraction)
                        HStack {
                            Button(intent: SkipBackwardIntent()) { Image(systemName: "gobackward.15") }
                                .accessibilityLabel("Skip back 15 seconds")
                            Button(intent: TogglePlaybackIntent()) { Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill") }
                                .accessibilityLabel(context.state.isPlaying ? liveActivityPauseLabel : liveActivityPlayLabel)
                            Button(intent: SkipForwardIntent()) { Image(systemName: "goforward.30") }
                                .accessibilityLabel("Skip forward 30 seconds")
                        }
                    }
                }
            } compactLeading: {
                cover(for: context, size: 22)
                    .clipShape(Circle())
            } compactTrailing: {
                if context.state.isPlaying {
                    Text(context.state.chapterTitle).lineLimit(1)
                } else {
                    Image(systemName: "pause.fill")
                }
            } minimal: {
                ProgressView(value: context.state.chapterFraction)
                    .progressViewStyle(.circular)
                    .overlay { Image(systemName: "waveform").font(.system(size: 8)) }
            }
            .widgetURL(URL(string: "voxglass://book/\(context.attributes.bookID.uuidString)"))
        }
    }

    @ViewBuilder
    private func cover(
        for context: ActivityViewContext<BookActivityAttributes>,
        size: CGFloat
    ) -> some View {
        if let url = CoverThumbnailStore.url(for: context.attributes.bookID),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .accessibilityLabel(context.attributes.title)
        } else {
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(Color(red: 0.16, green: 0.11, blue: 0.03))
                .frame(width: size, height: size)
                .overlay { Image(systemName: "waveform").foregroundStyle(.orange) }
                .accessibilityLabel(context.attributes.title)
        }
    }
}
