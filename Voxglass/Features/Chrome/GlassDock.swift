import SwiftUI
import VoxglassCore

struct GlassDock: View {
    @Environment(PlaybackCoordinator.self) var playback
    @EnvironmentObject private var miniPlayerRouter: MiniPlayerPresentationRouter
    @Binding var selectedTab: VoxglassTab
    @Binding var showingNowPlaying: Bool

    var body: some View {
        VStack(spacing: 9) {
            if let session = playback.currentSession,
               miniPlayerRouter.shouldShowMiniPlayer(currentBookID: session.book.id) {
                GlassMiniPlayer(showingNowPlaying: $showingNowPlaying)
                    .onTapGesture {
                        miniPlayerRouter.presentNowPlayingFromMiniPlayer(currentBookID: session.book.id)
                    }
                    .accessibilityIdentifier("chrome.miniPlayer")
            }
            GlassTabBar(selection: $selectedTab)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chrome.dock")
    }
}

struct GlassMiniPlayer: View {
    @Environment(PlaybackCoordinator.self) var playback
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if let session = playback.currentSession {
            HStack(spacing: 10) {
                BookArtworkView(title: session.book.title, size: 36, coverURL: session.book.coverURL, cornerRadius: 10)

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
                        if playback.playbackPhase == .preparing {
                            ProgressView()
                                .frame(minWidth: 44, minHeight: 44)
                        } else {
                            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .disabled(playback.playbackPhase == .preparing)
                    .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                    .accessibilityIdentifier("chrome.miniPlayer.playPause")
                    Button {
                        Task { await playback.skipToNextChapter() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Next chapter")
                    .accessibilityIdentifier("chrome.miniPlayer.nextChapter")
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
        (.listen, "headphones", "Listen"),
        (.library, "books.vertical.fill", "My Books"),
        (.discover, "square.grid.2x2.fill", "Discover"),
        (.narration, "mic.fill", "Narration")
    ]

    var body: some View {
        HStack {
            ForEach(items, id: \.0) { tab, icon, label in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon).scaledFont(size: 18)
                        Text(label)
                            .scaledFont(size: 9.5, weight: .medium)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selection == tab ? Palette.brass : Palette.ink3)
                    .frame(minHeight: 48)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        if selection == tab {
                            Capsule(style: .continuous)
                                .fill(Palette.brass.opacity(0.14))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .stroke(Palette.brass.opacity(0.32), lineWidth: 1)
                                }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(selection == tab ? "Selected" : "Not selected")
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .adaptiveGlass(cornerRadius: 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chrome.tabBar")
    }
}
