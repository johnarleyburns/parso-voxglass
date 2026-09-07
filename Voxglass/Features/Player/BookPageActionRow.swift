import SwiftUI
import VoxglassCore

struct BookPageActionRow: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @EnvironmentObject private var libraryStore: LibraryStore
    @EnvironmentObject private var offlineManager: OfflineDownloadManager
    @EnvironmentObject private var phoneAudioRelay: PhoneAudioRelay
    let book: BookWithChapters
    @Binding var showingEQ: Bool
    @Binding var showingBookmarks: Bool
    @Binding var showingOverflow: Bool
    @Binding var showCellularPrompt: Bool
    @Binding var showRemoveOfflineConfirm: Bool
    @State private var showDownloadSizeWarning = false
    @State private var showWatchSizeWarning = false
    @State private var showWatchCellularPrompt = false
    @State private var showRemoveWatchConfirm = false

    private var offlineState: OfflineState {
        // A local-files book (a folder import, or a personal-listening
        // export) is bookmark-referenced audio that's on-device by
        // definition — it never goes through OfflineDownloadManager's
        // download pipeline, so its dictionary lookup always falls through
        // to `.notCached` unless we special-case it here (same fix as the
        // My Books list row in LibraryView.swift).
        if isLocalFilesBook {
            return .cached
        }
        return offlineManager.state(for: book.book.id)
    }

    private var isLocalFilesBook: Bool {
        libraryStore.source(for: book.book)?.kind == .localFiles
    }

    private var watchState: WatchTransferState {
        phoneAudioRelay.watchStorageInfo(for: book.book.id)?.state ?? .notAvailable
    }

    /// No real byte count exists before a download finishes, so the
    /// space-usage warning shows an estimate from the book's total duration.
    private var estimatedBytes: Int64 {
        let totalDuration = book.chapters.reduce(0) { $0 + ($1.duration ?? 0) }
        return ByteFormatting.estimatedAudiobookBytes(duration: totalDuration)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullRow
            compactRow
        }
        .confirmationDialog(
            "Download this book?",
            isPresented: $showDownloadSizeWarning,
            titleVisibility: .visible
        ) {
            Button("Download") {
                Task { await startOffline(allowCellular: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will use approximately \(ByteFormatting.string(estimatedBytes)) of storage on your iPhone.")
        }
        .confirmationDialog(
            "Send to Apple Watch?",
            isPresented: $showWatchSizeWarning,
            titleVisibility: .visible
        ) {
            Button("Send to Watch") {
                Task { await startWatchTransfer(allowCellular: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will use approximately \(ByteFormatting.string(estimatedBytes)) of storage on your Apple Watch.")
        }
        .confirmationDialog(
            "Send to Apple Watch on cellular data?",
            isPresented: $showWatchCellularPrompt,
            titleVisibility: .visible
        ) {
            Button("Send now on cellular") {
                Task { await startWatchTransfer(allowCellular: true) }
            }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("Sending a book to the watch can use significant cellular data.")
        }
        .confirmationDialog(
            "Remove from Apple Watch?",
            isPresented: $showRemoveWatchConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove from Watch", role: .destructive) {
                Task { await phoneAudioRelay.removeBookFromWatch(bookID: book.book.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The book stays in My Books; only the copy on your Apple Watch is removed.")
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
            offlineButton
            Spacer(minLength: 0)
            watchButton
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
            offlineButton
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
                    TactileFeedback.tap()
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
                TactileFeedback.tap()
                playback.setSleepTimer(.off)
            } label: {
                sleepMenuLabel("Off", active: playback.sleepMode == .off)
            }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button {
                    TactileFeedback.tap()
                    playback.setSleepTimer(.duration(TimeInterval(minutes * 60)))
                } label: {
                    sleepMenuLabel("\(minutes) minutes", active: playback.sleepMode == .duration(TimeInterval(minutes * 60)))
                }
            }
            Button {
                TactileFeedback.tap()
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
            TactileFeedback.tap()
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

    @ViewBuilder
    private var offlineButton: some View {
        switch offlineState {
        case .notCached:
            Button {
                TactileFeedback.tap()
                showDownloadSizeWarning = true
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
            // A local-files book's audio isn't a separate "offline copy" to
            // remove — it's the original file the import pointed at, so
            // there's nothing for this button to do beyond showing that
            // it's present.
            if isLocalFilesBook {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 17, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("On this iPhone")
                    .accessibilityIdentifier("nowplaying.download")
            } else {
                Button {
                    TactileFeedback.tap()
                    showRemoveOfflineConfirm = true
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 17, weight: .semibold)
                        .foregroundStyle(Palette.brass)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Downloaded — tap to remove")
                .accessibilityIdentifier("nowplaying.download")
            }
        case .failed:
            Button {
                TactileFeedback.tap()
                showDownloadSizeWarning = true
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

    @ViewBuilder
    private var watchButton: some View {
        switch watchState {
        case .notAvailable, .failed:
            Button {
                TactileFeedback.tap()
                showWatchSizeWarning = true
            } label: {
                Image(systemName: "applewatch")
                    .scaledFont(size: 16)
                    .foregroundStyle(watchState == .failed ? Palette.danger : Color.white.opacity(0.6))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(watchState == .failed ? "Retry send to Apple Watch" : "Send to Apple Watch")
            .accessibilityIdentifier("nowplaying.watchDownload")
        case .queued, .waitingForPhone:
            ProgressView()
                .frame(width: 44, height: 44)
                .accessibilityLabel("Waiting to send to Apple Watch")
                .accessibilityIdentifier("nowplaying.watchDownload")
        case .transferring(let progress):
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(Palette.brass, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "applewatch")
                    .scaledFont(size: 9, weight: .semibold)
                    .foregroundStyle(Palette.brass)
            }
            .frame(width: 22, height: 22)
            .frame(width: 44, height: 44)
            .accessibilityElement()
            .accessibilityLabel("Sending to Apple Watch")
            .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            .accessibilityIdentifier("nowplaying.watchDownload")
        case .available:
            Button {
                TactileFeedback.tap()
                showRemoveWatchConfirm = true
            } label: {
                Image(systemName: "applewatch")
                    .symbolVariant(.fill)
                    .scaledFont(size: 16)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Downloaded to Apple Watch — tap to remove")
            .accessibilityIdentifier("nowplaying.watchDownload")
        }
    }

    private func startWatchTransfer(allowCellular: Bool) async {
        let start = await phoneAudioRelay.transferBookToWatch(book, allowCellularOverride: allowCellular)
        switch start {
        case .needsCellularConfirmation:
            showWatchCellularPrompt = true
        case .failed(let message):
            phoneAudioRelay.watchTransferError = message
        case .started:
            break
        }
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
            TactileFeedback.tap()
            showingOverflow = true
        } label: {
            Image(systemName: "ellipsis")
                .scaledFont(size: 16)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More options")
    }
}
