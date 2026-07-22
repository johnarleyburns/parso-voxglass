import SwiftUI
import VoxglassCore

struct BookPageActionRow: View {
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    let book: BookWithChapters
    @Binding var showingEQ: Bool
    @Binding var showingBookmarks: Bool
    @Binding var showingOverflow: Bool
    @Binding var showCellularPrompt: Bool
    @Binding var showRemoveOfflineConfirm: Bool

    private var offlineState: OfflineState {
        offlineManager.state(for: book.book.id)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullRow
            compactRow
        }
    }

    private var fullRow: some View {
        HStack(spacing: 0) {
            speedButton
            Spacer(minLength: 0)
            sleepTimerButton
            Spacer(minLength: 0)
            bookmarkButton
            Spacer(minLength: 0)
            favoriteButton
            Spacer(minLength: 0)
            offlineButton
            Spacer(minLength: 0)
            airplayButton
            Spacer(minLength: 0)
            overflowButton
        }
    }

    private var compactRow: some View {
        HStack(spacing: 0) {
            speedButton
            Spacer(minLength: 0)
            favoriteButton
            Spacer(minLength: 0)
            airplayButton
            Spacer(minLength: 0)
            overflowButton
        }
    }

    private var speedButton: some View {
        Menu {
            ForEach(PlaybackRate.menuLadder, id: \.self) { rate in
                Button {
                    playback.setPlaybackRate(rate)
                } label: {
                    if playback.playbackRate == rate {
                        Label(PlaybackRate.label(rate), systemImage: "checkmark")
                    } else {
                        Text(PlaybackRate.label(rate))
                    }
                }
            }
        } label: {
            Text(PlaybackRate.label(playback.playbackRate))
                .scaledFont(size: 13, weight: .bold, design: .monospaced)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PlaybackRate.label(playback.playbackRate))
        .accessibilityIdentifier("nowplaying.speed")
    }

    private var sleepTimerButton: some View {
        Menu {
            Button {
                playback.setSleepTimer(.off)
            } label: {
                sleepMenuLabel("Off", active: playback.sleepMode == .off)
            }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    playback.setSleepTimer(.duration(TimeInterval(minutes * 60)))
                } label: {
                    sleepMenuLabel("\(minutes) minutes", active: playback.sleepMode == .duration(TimeInterval(minutes * 60)))
                }
            }
            Button {
                playback.setSleepTimer(.endOfChapter)
            } label: {
                sleepMenuLabel("End of chapter", active: playback.sleepMode == .endOfChapter)
            }
        } label: {
            sleepTimerIcon
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepTimerAccessibilityValue)
        .accessibilityIdentifier("nowplaying.sleepTimer")
    }

    private var sleepTimerAccessibilityValue: String {
        switch playback.sleepMode {
        case .off:
            return "Off"
        case .endOfChapter:
            return "End of chapter"
        case .duration:
            if let remaining = playback.sleepRemaining {
                return "\(Int(remaining / 60)) minutes remaining"
            }
            return "On"
        }
    }

    @ViewBuilder
    private func sleepMenuLabel(_ title: String, active: Bool) -> some View {
        if active {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var sleepTimerIcon: some View {
        switch playback.sleepMode {
        case .off:
            Image(systemName: "moon.zzz")
                .scaledFont(size: 16)
        case .endOfChapter:
            Image(systemName: "moon.zzz.fill")
                .scaledFont(size: 16)
                .foregroundStyle(Palette.brass)
        case .duration:
            HStack(spacing: 3) {
                Image(systemName: "moon.zzz.fill")
                if let remaining = playback.sleepRemaining {
                    Text(sleepCountdown(remaining))
                        .scaledFont(size: 12, weight: .semibold, design: .monospaced)
                }
            }
            .foregroundStyle(Palette.brass)
        }
    }

    private func sleepCountdown(_ remaining: TimeInterval) -> String {
        let totalMinutes = Int((remaining / 60).rounded(.up))
        return "\(max(totalMinutes, 0))m"
    }

    private var bookmarkButton: some View {
        Button {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            playback.addBookmark()
            showingBookmarks = true
        } label: {
            Image(systemName: "bookmark")
                .scaledFont(size: 16)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Bookmark")
        .accessibilityIdentifier("nowplaying.bookmark")
    }

    private var favoriteButton: some View {
        let favorited = isFavorite
        return Button {
            Task { await libraryStore.setFavorite(!favorited, for: book.book.id) }
        } label: {
            Image(systemName: favorited ? "heart.fill" : "heart")
                .scaledFont(size: 16)
                .foregroundStyle(favorited ? Palette.brass : Color.white.opacity(0.6))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(favorited ? "Unfavorite" : "Favorite")
        .accessibilityIdentifier("nowplaying.favorite")
        .accessibilityAddTraits(favorited ? .isSelected : [])
    }

    private var isFavorite: Bool {
        libraryStore.book(withID: book.book.id)?.book.isFavorite ?? book.book.isFavorite
    }

    @ViewBuilder
    private var offlineButton: some View {
        switch offlineState {
        case .notCached:
            Button {
                Task { await requestOffline() }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .scaledFont(size: 17)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Download book")
            .accessibilityIdentifier("nowplaying.download")
        case .downloading(let progress):
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(Palette.brass, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Palette.brass)
            }
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .accessibilityElement()
            .accessibilityLabel("Downloading book")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            .accessibilityIdentifier("nowplaying.download")
        case .cached:
            Menu {
                Button("Remove offline copy", role: .destructive) {
                    showRemoveOfflineConfirm = true
                }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Downloaded")
            .accessibilityIdentifier("nowplaying.download")
        case .failed:
            Button {
                Task { await requestOffline() }
            } label: {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .scaledFont(size: 17)
                    .foregroundStyle(Palette.danger)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Retry download")
            .accessibilityIdentifier("nowplaying.download")
        }
    }

    private func requestOffline() async {
        await startOffline(allowCellular: false)
    }

    private func startOffline(allowCellular: Bool) async {
        let decision = await offlineManager.makeAvailableOffline(
            book: book,
            isCellular: NetworkMonitor.shared.isCellular,
            allowCellularOverride: allowCellular
        )
        switch decision {
        case .needsCellularConfirmation:
            showCellularPrompt = true
        case .start:
            break
        }
    }

    private var airplayButton: some View {
        RoutePickerButton()
            .frame(width: 40, height: 40)
            .accessibilityLabel("AirPlay")
    }

    private var overflowButton: some View {
        Button {
            showingOverflow = true
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 16)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More options")
    }
}
