import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var showingChapters = false
    @State private var showingEQ = false
    @State private var showPaywall = false

    /// Favorite state derived from the live library store (source of truth),
    /// falling back to the session's snapshot captured at play time.
    static func resolveFavorite(storeBook: BookWithChapters?, session: PlaybackSession) -> Bool {
        storeBook?.book.isFavorite ?? session.book.isFavorite
    }

    private func isFavorite(_ session: PlaybackSession) -> Bool {
        Self.resolveFavorite(storeBook: libraryStore.book(withID: session.book.id), session: session)
    }

    var body: some View {
        ZStack {
            VoxglassTheme.warmBackground.ignoresSafeArea()
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x8A5A24).opacity(0.28), .clear],
                        center: .top,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .blur(radius: 30)
                .ignoresSafeArea()

            if let session = playback.currentSession {
                VStack(spacing: 0) {
                    grabber
                    Spacer().frame(height: 16)
                    BookArtworkView(title: session.book.title, size: 240, coverURL: session.book.coverURL)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: .black.opacity(0.55), radius: 24, y: 0)
                    Spacer().frame(height: 22)
                    metadata(session)
                    scrubber(session)
                    controls(session)
                    actionBar(session)
                    chapterList(session)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
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
        .sheet(isPresented: $showingEQ) {
            NavigationStack {
                EQView()
                    .environmentObject(playback)
            }
            .presentationDragIndicator(.visible)
        }
        .paywallSheet(isPresented: $showPaywall)
    }

    private var grabber: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.white.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.top, 6)
    }

    private func metadata(_ session: PlaybackSession) -> some View {
        VStack(spacing: 6) {
            Text(session.book.title)
                .font(.system(size: 17, weight: .bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .foregroundStyle(Palette.ink)
            Text(session.book.authorLine)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
            Text(session.chapter.title)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.50))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
    }

    private func scrubber(_ session: PlaybackSession) -> some View {
        VStack(spacing: 7) {
            let duration = max(session.duration ?? session.position, 1)
            let progress = scrubPosition / duration

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 7)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.90))
                        .frame(width: max(geometry.size.width * CGFloat(progress), 0), height: 7)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            isScrubbing = true
                            let ratio = val.location.x / geometry.size.width
                            scrubPosition = max(0, min(duration, Double(ratio) * duration))
                        }
                        .onEnded { _ in
                            isScrubbing = false
                            Task { await playback.seek(to: scrubPosition) }
                        }
                )
            }
            .frame(height: 7)

            HStack {
                Text(TimeFormatting.clock(isScrubbing ? scrubPosition : session.position))
                Spacer()
                if let bookRemaining = session.bookRemaining {
                    Text("\(TimeFormatting.compactDuration(bookRemaining)) left in book")
                    Spacer()
                }
                Text("-\(TimeFormatting.clock(max((session.duration ?? 0) - (isScrubbing ? scrubPosition : session.position), 0)))")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(.horizontal, 2)
        .padding(.top, 20)
    }

    private func controls(_ session: PlaybackSession) -> some View {
        HStack(spacing: 14) {
            Button {
                Task { await playback.skipToPreviousChapter() }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .accessibilityLabel("Previous chapter")

            Button {
                Task { await playback.skip(by: -15) }
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .accessibilityLabel("Back 15 seconds")

            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 66, height: 66)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .accessibilityLabel(session.isPlaying ? "Pause" : "Play")

            Button {
                Task { await playback.skip(by: 30) }
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .accessibilityLabel("Forward 30 seconds")

            Button {
                Task { await playback.skipToNextChapter() }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassSurface(cornerRadius: 26, fill: Color.white.opacity(0.12))
            }
            .accessibilityLabel("Next chapter")
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
    }

    private func actionBar(_ session: PlaybackSession) -> some View {
        HStack(spacing: 30) {
            Button {
                showingChapters = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16))
            }
            .accessibilityLabel("Chapters")

            favoriteButton(session)

            equalizerButton

            Button {} label: {
                Image(systemName: "timer")
                    .font(.system(size: 16))
            }
            .disabled(true)

            ShareLink(item: "\(session.book.title) by \(session.book.authorLine)") {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16))
            }
        }
        .foregroundStyle(Color.white.opacity(0.6))
        .padding(.top, 16)
    }

    private func favoriteButton(_ session: PlaybackSession) -> some View {
        let favorited = isFavorite(session)
        return Button {
            Task { await libraryStore.setFavorite(!favorited, for: session.book.id) }
        } label: {
            Image(systemName: favorited ? "heart.fill" : "heart")
                .font(.system(size: 16))
                .foregroundStyle(favorited ? Palette.brass : Color.white.opacity(0.6))
        }
        .accessibilityLabel(favorited ? "Unfavorite" : "Favorite")
        .accessibilityIdentifier("nowplaying.favorite")
        .accessibilityAddTraits(favorited ? .isSelected : [])
    }

    @ViewBuilder
    private var equalizerButton: some View {
        if ProFeature.isEnabled(.eq) {
            Button {
                showingEQ = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
            }
            .accessibilityLabel("Equalizer")
            .accessibilityIdentifier("nowplaying.eq")
        } else {
            Button {
                showPaywall = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16))
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(x: 6, y: -6)
                    }
            }
            .accessibilityLabel("Equalizer (Pro)")
            .accessibilityIdentifier("pro.lock.eq")
        }
    }

    private func chapterList(_ session: PlaybackSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
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
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.58))
                    }
                    .font(.system(size: 14))
                    .padding(.vertical, 4)
                    .foregroundStyle(chapter.id == session.chapter.id ? Palette.brass : Color.white.opacity(0.82))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassSurface(cornerRadius: 14, fill: Color.white.opacity(0.06))
        .padding(.top, 16)
    }
}
