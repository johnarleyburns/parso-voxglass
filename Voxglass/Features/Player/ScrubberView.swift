import SwiftUI
import VoxglassCore

struct ScrubberView: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let isActiveBook: Bool
    let chapterFallbackPosition: TimeInterval
    let chapterFallbackDuration: TimeInterval
    let elapsedBeforeChapter: TimeInterval
    let totalBookDuration: TimeInterval?
    let onSeekChapterPosition: (TimeInterval) -> Void

    @State private var isScrubbing = false
    @State private var scrubPosition: TimeInterval = 0

    private var liveChapterPosition: TimeInterval {
        if isActiveBook {
            return playback.playhead
        }
        return chapterFallbackPosition
    }

    private var liveChapterDuration: TimeInterval {
        if isActiveBook,
           let duration = playback.playheadDuration,
           duration.isFinite,
           duration > 0 {
            return duration
        }

        if chapterFallbackDuration.isFinite,
           chapterFallbackDuration > 0 {
            return chapterFallbackDuration
        }

        return 1
    }

    var body: some View {
        let chapterPosition = isScrubbing ? scrubPosition : liveChapterPosition
        let chapterDuration = liveChapterDuration
        let chapterProgress = min(max(chapterDuration > 0 ? chapterPosition / chapterDuration : 0, 0), 1)
        let bookElapsed = elapsedBeforeChapter + chapterPosition
        let bookRemaining = totalBookDuration.map { max($0 - bookElapsed, 0) }

        VStack(spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 7)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isActiveBook ? Color.white.opacity(0.90) : Palette.brass.opacity(0.85))
                        .frame(width: max(geometry.size.width * CGFloat(chapterProgress), 0), height: 7)

                    Circle()
                        .fill(.white)
                        .frame(width: isScrubbing ? 20 : 13, height: isScrubbing ? 20 : 13)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .offset(x: max(0, min(geometry.size.width - (isScrubbing ? 20 : 13), geometry.size.width * CGFloat(chapterProgress) - (isScrubbing ? 10 : 6.5))))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            guard isActiveBook else { return }
                            isScrubbing = true
                            let ratio = val.location.x / geometry.size.width
                            scrubPosition = max(0, min(chapterDuration, Double(ratio) * chapterDuration))
                        }
                        .onEnded { _ in
                            guard isActiveBook else { return }
                            let target = scrubPosition
                            isScrubbing = false
                            onSeekChapterPosition(target)
                        }
                )
            }
            .frame(height: 32)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormatting.clock(chapterPosition))
            .accessibilityIdentifier("nowplaying.scrubber")
            .accessibilityAdjustableAction { direction in
                guard isActiveBook else { return }
                let delta: TimeInterval = direction == .increment ? 30 : -15
                let target = max(0, min(chapterDuration, liveChapterPosition + delta))
                scrubPosition = target
                onSeekChapterPosition(target)
            }

            HStack {
                Text(TimeFormatting.clock(chapterPosition))
                Spacer()
                if let bookRemaining, bookRemaining > 0 {
                    Text("\(TimeFormatting.compactDuration(bookRemaining)) left in book")
                    Spacer()
                }
                Text("-\(TimeFormatting.clock(max(chapterDuration - chapterPosition, 0)))")
            }
            .scaledFont(size: 11)
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.55))

            if let totalBookDuration, totalBookDuration > 0 {
                GeometryReader { geometry in
                    Capsule()
                        .fill(Palette.brass.opacity(0.80))
                        .frame(width: max(2, geometry.size.width * CGFloat(min(max(bookElapsed / totalBookDuration, 0), 1))), height: 2)
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 20)
    }
}
