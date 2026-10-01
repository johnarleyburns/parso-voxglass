import SwiftUI
import VoxglassCore

struct MiniPlayerAccessory: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(MiniPlayerPresentationRouter.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @State private var userToggleCount = 0
    @State private var skipBackCount = 0
    @State private var skipForwardCount = 0

    var body: some View {
        if let session = playback.currentSession,
           router.shouldShowMiniPlayer(currentBookID: session.book.id) {
            HStack(spacing: 10) {
                Button {
                    router.presentNowPlayingFromMiniPlayer(currentBookID: session.book.id)
                } label: {
                    HStack(spacing: 10) {
                        CoverPlate(title: session.book.title, author: session.book.authorLine, coverURL: session.book.coverURL, size: placement == .inline ? 28 : 32, shape: .circle)
                        titleText(session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                Spacer(minLength: 4)
                Button {
                    userToggleCount += 1
                    playback.togglePlayPause()
                } label: {
                    playPauseSymbol(isPlaying: session.isPlaying)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play") // l10n-exempt: state-dependent accessibility or status copy
                .accessibilityIdentifier("chrome.miniPlayer.playPause")
                .sensoryFeedback(.impact(weight: .light), trigger: userToggleCount)
                if placement == .expanded {
                    expandedControls
                }
            }
            .padding(.horizontal, 10)
            .frame(height: placement == .inline ? 50 : 60)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("chrome.miniPlayer")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now playing, \(session.book.title), \(session.chapter.title), \(session.isPlaying ? "playing" : "paused")")
            .accessibilityAction(named: session.isPlaying ? String(localized: "Pause") : String(localized: "Play")) {
                playback.togglePlayPause()
            }
            .accessibilityAction(named: "Skip forward \(forwardInterval) seconds") {
                skipForwardCount += 1
                Task { await playback.skip(by: TimeInterval(forwardInterval)) }
            }
            .accessibilityAction(named: "Skip back \(backInterval) seconds") {
                skipBackCount += 1
                Task { await playback.skip(by: -TimeInterval(backInterval)) }
            }
            .accessibilityAction(named: "Open player") {
                router.presentNowPlayingFromMiniPlayer(currentBookID: session.book.id)
            }
        } else {
            // Keep the accessory structurally registered (which avoids the iOS
            // launch loop) without leaving an empty capsule on non-player tabs.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private func titleText(_ session: PlaybackSession) -> some View {
        Text(session.book.title)
            .voxType(.body)
            .lineLimit(2)
            .minimumScaleFactor(0.62)
            .allowsTightening(true)
    }

    private var backInterval: Int {
        let value = UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipBackInterval)
        return value > 0 ? value : 15
    }

    private var forwardInterval: Int {
        let value = UserDefaults.standard.integer(forKey: AppPreferencesStore.Keys.skipForwardInterval)
        return value > 0 ? value : 30
    }

    private func playPauseSymbol(isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .frame(minWidth: 44, minHeight: 44)
            .contentTransition(.symbolEffect(.replace.downUp))
    }

    @ViewBuilder
    private var expandedControls: some View {
        Button {
            skipBackCount += 1
            Task { await playback.skip(by: -TimeInterval(backInterval)) }
        } label: {
            Image(systemName: SkipSymbol.back(backInterval))
                .frame(minWidth: 44, minHeight: 44)
                .symbolEffect(.bounce.byLayer, value: skipBackCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip back \(backInterval) seconds")
        .accessibilityIdentifier("chrome.miniPlayer.skipBackward")
        .sensoryFeedback(.impact(flexibility: .soft), trigger: skipBackCount)
        Button {
            skipForwardCount += 1
            Task { await playback.skip(by: TimeInterval(forwardInterval)) }
        } label: {
            Image(systemName: SkipSymbol.forward(forwardInterval))
                .frame(minWidth: 44, minHeight: 44)
                .symbolEffect(.bounce.byLayer, value: skipForwardCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip forward \(forwardInterval) seconds")
        .accessibilityIdentifier("chrome.miniPlayer.skipForward")
        .sensoryFeedback(.impact(flexibility: .soft), trigger: skipForwardCount)
    }
}
