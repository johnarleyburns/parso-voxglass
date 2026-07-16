import SwiftUI
import VoxglassCore

struct GlassDock: View {
    @EnvironmentObject var playback: PlaybackCoordinator
    @Binding var selectedTab: VoxglassTab
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VStack(spacing: 9) {
            if playback.currentSession != nil {
                GlassMiniPlayer(showingNowPlaying: $showingNowPlaying)
                    .onTapGesture { showingNowPlaying = true }
            }
            GlassTabBar(selection: $selectedTab)
        }
        .padding(.horizontal, 12)
    }
}

struct GlassMiniPlayer: View {
    @EnvironmentObject var playback: PlaybackCoordinator
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let session = playback.currentSession {
            HStack(spacing: 10) {
                BookArtworkView(title: session.book.title, size: 36, coverURL: session.book.coverURL)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.book.title)
                        .scaledFont(size: 12.5, weight: .semibold)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(subtitle(session))
                        .scaledFont(size: 10.5)
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 16) {
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button {
                        Task { await playback.skipToNextChapter() }
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .scaledFont(size: 16)
                .foregroundStyle(Palette.ink)
                .buttonStyle(.plain)
            }
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 14))
            .adaptiveGlass(cornerRadius: 22)
        }
    }

    private func subtitle(_ session: PlaybackSession) -> String {
        "\(session.chapter.title) · \(TimeFormatting.clock(session.duration))"
    }
}

struct GlassTabBar: View {
    @Binding var selection: VoxglassTab

    private let items: [(VoxglassTab, String, String)] = [
        (.home, "headphones", "Listen"),
        (.library, "books.vertical.fill", "My Books"),
        (.browse, "square.grid.2x2.fill", "Explore"),
        (.search, "magnifyingglass", "Search"),
        (.more, "ellipsis.circle.fill", "More")
    ]

    var body: some View {
        HStack {
            ForEach(items, id: \.0) { tab, icon, label in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon).scaledFont(size: 18)
                        Text(label).scaledFont(size: 9.5, weight: .medium)
                    }
                    .foregroundStyle(selection == tab ? Palette.brass : Palette.ink3)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(label)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .adaptiveGlass(cornerRadius: 26)
    }
}
