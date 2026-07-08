import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var showingChapters = false

    var body: some View {
        ZStack {
            VoxglassTheme.deepGlass.ignoresSafeArea()
            if let session = playback.currentSession {
                VStack(spacing: 22) {
                    header
                    Spacer(minLength: 0)
                    BookArtworkView(title: session.book.title, size: 220)
                        .shadow(color: .black.opacity(0.35), radius: 28, y: 20)
                    metadata(session)
                    scrubber(session)
                    controls(session)
                    actionBar(session)
                    chapterList(session)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .foregroundStyle(.white)
                .onAppear {
                    scrubPosition = session.position
                }
                .onChange(of: session.position) { _, newValue in
                    if !isScrubbing {
                        scrubPosition = newValue
                    }
                }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "headphones")
                    .foregroundStyle(.white)
            }
        }
        .sheet(isPresented: $showingChapters) {
            if let session = playback.currentSession {
                NavigationStack {
                    ChaptersView(
                        book: BookWithChapters(book: session.book, chapters: session.chapters),
                        showingNowPlaying: .constant(true)
                    )
                }
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            Spacer()
            Text("Now Playing")
                .font(.headline)
            Spacer()
            Image(systemName: "airplayaudio")
                .font(.headline)
                .frame(width: 42, height: 42)
                .accessibilityLabel("AirPlay")
        }
    }

    private func metadata(_ session: PlaybackSession) -> some View {
        VStack(spacing: 6) {
            Text(session.book.title)
                .font(.title2.weight(.bold))
                .fontDesign(.serif)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            Text(session.book.authorLine)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
            Text(session.chapter.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
    }

    private func scrubber(_ session: PlaybackSession) -> some View {
        VStack(spacing: 6) {
            Slider(
                value: $scrubPosition,
                in: 0...max(session.duration ?? session.position, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        Task { await playback.seek(to: scrubPosition) }
                    }
                }
            )
            .tint(VoxglassTheme.accent)

            HStack {
                Text(TimeFormatting.clock(isScrubbing ? scrubPosition : session.position))
                Spacer()
                Text("-\(TimeFormatting.clock(max((session.duration ?? 0) - (isScrubbing ? scrubPosition : session.position), 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))
        }
    }

    private func controls(_ session: PlaybackSession) -> some View {
        HStack(spacing: 24) {
            Button {
                Task { await playback.skipToPreviousChapter() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous chapter")

            Button {
                Task { await playback.skip(by: -15) }
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back 15 seconds")

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .bold))
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(.white))
                    .foregroundStyle(VoxglassTheme.ink)
            }
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

            Button {
                Task { await playback.skip(by: 30) }
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Forward 30 seconds")

            Button {
                Task { await playback.skipToNextChapter() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next chapter")
        }
        .buttonStyle(.plain)
    }

    private func actionBar(_ session: PlaybackSession) -> some View {
        HStack(spacing: 10) {
            PlayerActionButton(title: "Chapters", systemImage: "list.bullet", isEnabled: true) {
                showingChapters = true
            }
            PlayerActionButton(title: "1x", systemImage: "speedometer", isEnabled: false) {}
            PlayerActionButton(title: "Sleep", systemImage: "timer", isEnabled: false) {}
            PlayerActionButton(title: "Mark", systemImage: "bookmark", isEnabled: false) {}
            ShareLink(item: "\(session.book.title) by \(session.book.authorLine)") {
                VStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                    Text("Share")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(.white)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.08))
                }
            }
        }
    }

    private func chapterList(_ session: PlaybackSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.headline)
            ForEach(session.chapters.prefix(6)) { chapter in
                Button {
                    Task {
                        if chapter.id == session.chapter.id {
                            await playback.seek(to: 0)
                        } else {
                            await playback.play(BookWithChapters(book: session.book, chapters: session.chapters), chapter: chapter)
                        }
                    }
                } label: {
                    HStack {
                        Text(chapter.title)
                            .lineLimit(1)
                        Spacer()
                        Text(TimeFormatting.clock(chapter.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.58))
                    }
                    .font(.subheadline)
                    .padding(.vertical, 4)
                    .foregroundStyle(chapter.id == session.chapter.id ? VoxglassTheme.accent : .white.opacity(0.82))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }
}

private struct PlayerActionButton: View {
    var title: String
    var systemImage: String
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.headline)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.42))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(isEnabled ? 0.08 : 0.04))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
