import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

private let liveActivityPauseLabel = String(localized: "Pause")
private let liveActivityPlayLabel = String(localized: "Play")

struct BookLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BookActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            let rateText = context.state.rate.formatted(.number.precision(.fractionLength(1)))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    cover(for: context, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title).widgetAccentable()
                        Text("Chapter \(context.state.chapterIndex) of \(context.state.chapterCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(context.state.chapterTitle).font(.caption)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(rateText)×")
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel("Playback speed \(rateText) times")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if context.state.isPlaying, let start = context.state.progressStart, let end = context.state.progressEnd, start < end {
                            ProgressView(timerInterval: start...end, countsDown: false)
                                .tint(Color.voxglassBrass)
                        } else {
                            ProgressView(value: context.state.chapterFraction)
                                .tint(Color.voxglassBrass)
                        }
                        HStack(spacing: 24) {
                            Button(intent: SkipBackwardIntent()) {
                                Image(systemName: SkipSymbols.back(context.state.skipBack))
                            }
                            .accessibilityLabel("Skip back \(context.state.skipBack) seconds")

                            Button(intent: TogglePlaybackIntent()) {
                                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                            }
                            .accessibilityLabel(context.state.isPlaying ? liveActivityPauseLabel : liveActivityPlayLabel)

                            Button(intent: SkipForwardIntent()) {
                                Image(systemName: SkipSymbols.forward(context.state.skipForward))
                            }
                            .accessibilityLabel("Skip forward \(context.state.skipForward) seconds")

                            Button(intent: CycleSleepTimerIntent()) {
                                Image(systemName: context.state.sleepUntil != nil || context.state.sleepEndOfChapter ? "moon.fill" : "moon")
                            }
                            .accessibilityLabel("Sleep timer")
                        }
                    }
                }
            } compactLeading: {
                cover(for: context, size: 22)
                    .clipShape(Circle())
            } compactTrailing: {
                if context.state.isPlaying {
                    if let end = context.state.progressEnd {
                        Text(timerInterval: Date()...end, countsDown: true)
                            .monospacedDigit()
                            .frame(width: 38)
                    } else {
                        Text(context.state.chapterTitle)
                    }
                } else {
                    Image(systemName: "pause.fill")
                }
            } minimal: {
                if context.state.isPlaying, let start = context.state.progressStart, let end = context.state.progressEnd, start < end {
                    ProgressView(timerInterval: start...end, countsDown: false)
                        .progressViewStyle(.circular)
                        .tint(Color.voxglassBrass)
                        .overlay { Image(systemName: "waveform").font(.caption2).imageScale(.small).foregroundStyle(Color.voxglassBrass) }
                } else {
                    ProgressView(value: context.state.chapterFraction)
                        .progressViewStyle(.circular)
                        .tint(Color.voxglassBrass)
                        .overlay { Image(systemName: "waveform").font(.caption2).imageScale(.small) }
                }
            }
            .widgetURL(URL(string: "voxglass://book/\(context.attributes.bookID.uuidString)"))
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<BookActivityAttributes>) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                cover(for: context, size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voxglass · Chapter \(context.state.chapterIndex) of \(context.state.chapterCount)")
                        .textCase(.uppercase)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.voxglassBrass)
                    Text(context.attributes.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(detailLine(context: context))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 4)
                if let sleepText = sleepCapsuleText(context.state) {
                    HStack(spacing: 4) {
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                        Text(sleepText)
                            .font(.caption2.weight(.medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .foregroundStyle(.white)
                }
            }

            if context.state.isPlaying, let start = context.state.progressStart, let end = context.state.progressEnd, start < end {
                ProgressView(timerInterval: start...end, countsDown: false)
                    .tint(Color.voxglassBrass)
            } else {
                ProgressView(value: context.state.chapterFraction)
                    .tint(Color.voxglassBrass)
            }

            HStack {
                if context.state.isPlaying,
                   let start = context.state.progressStart,
                   start < Date() {
                    Text(timerInterval: start...Date(), countsDown: false)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("\(Int((context.state.chapterFraction * 100).rounded()))% elapsed")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if let remainingInBook = context.state.bookRemaining, remainingInBook > 0 {
                    let remaining = Duration.seconds(Int(remainingInBook) / 60 * 60)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                    Text("\(remaining) left in book")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                if context.state.isPlaying,
                   let end = context.state.progressEnd,
                   Date() < end {
                    Text(timerInterval: Date()...end, countsDown: true)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("\(Int(((1 - context.state.chapterFraction) * 100).rounded()))% left")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text("\(context.state.rate.formatted(.number.precision(.fractionLength(0...2))))×")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.voxglassBrass)
            }

            HStack(spacing: 16) {
                Button(intent: SkipBackwardIntent()) {
                    Image(systemName: SkipSymbols.back(context.state.skipBack))
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip back \(context.state.skipBack) seconds")

                Spacer()

                Button(intent: TogglePlaybackIntent()) {
                    Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(context.state.isPlaying ? liveActivityPauseLabel : liveActivityPlayLabel)

                Spacer()

                Button(intent: SkipForwardIntent()) {
                    Image(systemName: SkipSymbols.forward(context.state.skipForward))
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip forward \(context.state.skipForward) seconds")

                Spacer()

                Button(intent: CycleSleepTimerIntent()) {
                    Image(systemName: context.state.sleepUntil != nil || context.state.sleepEndOfChapter ? "moon.fill" : "moon")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sleep timer")
            }
        }
        .padding(14)
        .activityBackgroundTint(Color(red: 0.08, green: 0.09, blue: 0.11))
        .activitySystemActionForegroundColor(Color.voxglassBrass)
    }

    private func detailLine(context: ActivityViewContext<BookActivityAttributes>) -> String {
        var parts: [String] = [context.state.chapterTitle]
        if let narrator = context.attributes.narrator, !narrator.isEmpty {
            parts.append(narrator)
        }
        return parts.joined(separator: " · ")
    }

    private func sleepCapsuleText(_ state: BookActivityAttributes.ContentState) -> String? {
        if state.sleepEndOfChapter {
            return String(localized: "☾ End of chapter")
        }
        if let until = state.sleepUntil, until > Date() {
            let mins = max(1, Int(until.timeIntervalSinceNow / 60))
            return "☾ " + Duration.seconds(mins * 60).formatted(.units(allowed: [.minutes], width: .abbreviated))
        }
        return nil
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

private extension Color {
    /// Voxglass brass (the app's accent asset), defined once for the Live
    /// Activity, which renders outside the app and cannot read its catalog.
    static let voxglassBrass = Color(red: 0.89, green: 0.64, blue: 0.29)
}
