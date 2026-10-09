import SwiftUI
import WatchKit
import VoxglassWatchCore
import VoxglassWatchProtocol

// Watch redesign §5 C1–C3 and D1.

/// C1 — Chapters. Opens scrolled to the current chapter: ✓ finished, a ring for the current one,
/// a dot for what's ahead; chapters that can't play here are dimmed with the reason. Tapping one
/// plays it and returns to the Player. Previous/Next chapter live here (the face skips time).
struct WatchChaptersView: View {
    let book: WatchBookDTO
    @Binding var path: [WatchRoute]
    @EnvironmentObject private var services: WatchAppServices

    private var isCurrentBook: Bool { services.playbackBook?.id == book.id }
    private var currentIndex: Int { isCurrentBook ? services.playback.chapterIndex : services.resumeChapterIndex(for: book) }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if isCurrentBook {
                    HStack(spacing: 6) {
                        Button { services.previousChapter(); returnToPlayer() } label: {
                            Label("Previous", systemImage: "backward.end.fill")
                        }
                        .buttonStyle(.watchSecondarySmall)
                        .disabled(!services.playback.canGoPrevious)
                        .accessibilityLabel(Text("Previous chapter"))
                        .accessibilityIdentifier("watch.book.previousChapter")
                        Button { services.nextChapter(); returnToPlayer() } label: {
                            Label("Next", systemImage: "forward.end.fill")
                        }
                        .buttonStyle(.watchSecondarySmall)
                        .disabled(!services.playback.canGoNext)
                        .accessibilityLabel(Text("Next chapter"))
                        .accessibilityIdentifier("watch.book.nextChapter")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(book.chapters, id: \.id) { chapter in
                    Button { play(chapter.index) } label: { row(chapter) }
                        .buttonStyle(.plain)
                        .disabled(!isPlayable(chapter))
                        .opacity(isPlayable(chapter) ? 1 : 0.45)
                        .watchCardRow(current: chapter.index == currentIndex)
                        .id(chapter.index)
                        .accessibilityIdentifier("watch.chapter.\(chapter.id.rawValue)")
                        .accessibilityLabel(Text("Chapter \(chapter.index + 1), \(chapter.title)"))
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chapters")
            .onAppear { proxy.scrollTo(currentIndex, anchor: .center) }
        }
    }

    private func row(_ chapter: WatchChapterDTO) -> some View {
        HStack(spacing: 8) {
            if chapter.index < currentIndex {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(WatchPalette.success)
                    .frame(width: 22).accessibilityLabel(Text("Finished"))
            } else if chapter.index == currentIndex {
                WatchTransferRing(fraction: isCurrentBook ? services.playback.progress : 0, size: 22)
                    .accessibilityLabel(Text("Current chapter"))
            } else {
                Circle().fill(Color.secondary).frame(width: 4, height: 4).frame(width: 22)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(chapter.title).font(.body).lineLimit(2)
                Text(detail(chapter)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ chapter: WatchChapterDTO) -> String {
        if !isPlayable(chapter) { return String(localized: "Not on this watch") }
        if chapter.index == currentIndex, isCurrentBook {
            return String(localized: "\(WatchTimeFormat.clock(max(0, services.playback.duration - services.playback.position))) left")
        }
        return WatchTimeFormat.clock(chapter.duration)
    }

    private func isPlayable(_ chapter: WatchChapterDTO) -> Bool {
        services.downloaded.contains(book.id)
    }

    private func play(_ index: Int) {
        WKInterfaceDevice.current().play(.click)
        if isCurrentBook { services.jump(toChapter: index) } else { services.play(book, chapterIndex: index) }
        returnToPlayer()
    }

    private func returnToPlayer() {
        if let playerIndex = path.lastIndex(of: .player) {
            path.removeSubrange((playerIndex + 1)...)
        } else {
            path.removeLast()
            path.append(.player)
        }
    }
}

/// C2 — Speed. A big numeral the Crown turns in 0.05 steps (a stronger detent haptic every 0.25),
/// two presets, applied instantly with pitch correction and remembered per book.
struct WatchSpeedView: View {
    @EnvironmentObject private var services: WatchAppServices
    @State private var rate = 1.0

    var body: some View {
        VStack(spacing: 8) {
            Text("Speed").font(.caption2).foregroundStyle(.secondary)
            Text(verbatim: WatchSpeed.label(rate))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .accessibilityIdentifier("watch.speed.value")
            Text("Turn the Crown · 0.5× – 3×").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(WatchSpeed.presets, id: \.self) { preset in
                    Button { rate = preset } label: { Text(verbatim: WatchSpeed.label(preset)) }
                        .buttonStyle(WatchPillButtonStyle(kind: abs(rate - preset) < 0.01 ? .primary : .secondary, small: true))
                }
            }
        }
        .padding(.horizontal, 6)
        .focusable()
        .digitalCrownRotation($rate, from: WatchSpeed.minimum, through: WatchSpeed.maximum, by: WatchSpeed.step,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: false)
        .onAppear { rate = services.playback.rate }
        .onChange(of: rate) { _, value in
            let normalized = WatchSpeed.normalized(value)
            WKInterfaceDevice.current().play(WatchSpeed.isDetent(normalized) ? .click : .directionUp)
            services.setRate(normalized)
        }
        .navigationTitle("Speed")
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            rate = WatchSpeed.normalized(rate + (direction == .increment ? 0.25 : -0.25))
        }
    }
}

/// C3 — Sleep timer. End of Chapter or minutes; the last 10 s fade, the position is saved, a soft
/// haptic marks the stop. Cancel from the same list.
struct WatchSleepView: View {
    @EnvironmentObject private var services: WatchAppServices
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(WatchSleepTimer.choices, id: \.self) { mode in
                Button {
                    services.setSleepTimer(mode)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(mode))
                            if services.sleepTimer?.mode == mode, let remaining = services.sleepRemaining {
                                Text("in \(WatchTimeFormat.short(remaining))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if services.sleepTimer?.mode == mode {
                            Image(systemName: "checkmark").foregroundStyle(WatchPalette.accent)
                        }
                    }
                }
                .watchCardRow(current: services.sleepTimer?.mode == mode)
            }
            Button {
                services.setSleepTimer(nil)
                dismiss()
            } label: { Text("Off") }
                .watchCardRow(current: services.sleepTimer == nil)
                .accessibilityIdentifier("watch.sleep.off")
        }
        .listStyle(.plain)
        .navigationTitle("Sleep Timer")
    }

    private func title(_ mode: WatchSleepTimer.Mode) -> String {
        switch mode {
        case .endOfChapter: String(localized: "End of Chapter")
        case .minutes(let minutes): String(localized: "\(minutes) minutes")
        }
    }
}

/// D1 — Downloads: what's downloading, how far, and the specific reason it's waiting, with Pause /
/// Resume / Stop on the same screen; then storage used by books on this watch.
struct WatchDownloadsView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        List {
            Text("Send and manage books from Voxglass on your iPhone.").font(.caption2)
            ForEach(services.visibleBooks, id: \.id) { book in
                Label(book.title, systemImage: "book.closed").watchCardRow()
            }
            if services.visibleBooks.isEmpty { Text("No books installed on this watch.").font(.caption2) }
        }.navigationTitle("On This Watch").listStyle(.plain)
    }
}

/// Connection and metadata are distinct from installed audio; no download/retry actions.
struct WatchListeningSyncStatusView: View {
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        List {
            Section("iPhone") {
                Text(services.isConnected ? String(localized: "iPhone connected") : String(localized: "iPhone not connected"))
                Button("Sync Now") { services.session.syncNow() }
                    .disabled(!services.isConnected || services.session.isSyncing)
                if !services.isConnected { Text("Sync Now available when connected to iPhone.").font(.caption2) }
                if let message = services.session.syncMessage { Text(message).font(.caption2) }
                if let date = services.session.lastCatalogDate { Text("Last iPhone catalog: \(date.formatted())").font(.caption2) }
            }
            Section("Installed audio") {
                Text("\(services.downloaded.count) books on this watch")
                ForEach(services.books.filter { !services.downloaded.contains($0.id) }, id: \.id) { book in
                    VStack(alignment: .leading) {
                        Text(book.title)
                        let count = services.session.bookReports[book.id]?.installedChapterIDs?.count ?? 0
                        Text("\(count) of \(book.chapters.count) chapters installed").font(.caption2)
                        if case .failed(let message)? = services.session.snapshot?.downloadStates?[book.id] {
                            Text(message).font(.caption2)
                        } else { Text("Audio submitted by iPhone; installation is unconfirmed.").font(.caption2) }
                    }
                }
            }
            Section("Diagnostics") {
                Button("Refresh") { services.session.refresh() }
                Text("Audio receipt: " + services.session.audioReceipt).font(.caption2)
                Text("Artwork receipt: " + services.session.artworkReceipt).font(.caption2)
                Text("Watch report: " + services.session.reportMessage).font(.caption2)
                if let error = services.session.connectionError { Text(error).font(.caption2) }
            }
        }.navigationTitle("Sync Status").listStyle(.plain)
    }
}
