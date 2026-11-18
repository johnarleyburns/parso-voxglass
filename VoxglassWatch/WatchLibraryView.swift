import SwiftUI
import WatchKit
import VoxglassWatchCore
import VoxglassWatchProtocol

/// Watch redesign §5 H1–H3 — "Continue Listening" Home. The book you're in comes first as a hero
/// (cover, chapter, time left, one play button); then the library, sorted by last listened, each
/// row with progress and where it lives; then a quiet footer: connection chip, Downloads, About.
/// Replaces the plain text list, the waveform toolbar shortcut and the 2.5 s connection toast.
struct WatchHomeView: View {
    @EnvironmentObject private var services: WatchAppServices
    @Binding var path: [WatchRoute]
    @State private var pendingRemoval: WatchBookDTO?

    var body: some View {
        List {
            if services.session.isReconciling {
                ProgressView("Checking installed books…").font(.caption2)
            }
            if let hero = services.heroBook {
                heroCard(hero)
                    .onLongPressGesture { pendingRemoval = hero }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if services.visibleBooks.isEmpty && !services.session.isReconciling {
                emptyCard
                    .listRowBackground(Color.clear)
            } else {
                Section("Library") {
                    ForEach(services.visibleBooks.filter { $0.id != services.heroBook?.id }, id: \.id) { book in
                        Button { open(book) } label: { WatchBookRow(book: book) }
                            .buttonStyle(.plain)
                            .onLongPressGesture { pendingRemoval = book }
                            .watchCardRow()
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(watchBookAccessibilityLabel(book))
                            .accessibilityHint(Text("Double-tap to open"))
                            .accessibilityIdentifier("watch.book.\(book.id.rawValue)")
                    }
                }
            }
            footer
        }
        .listStyle(.plain)
        .navigationTitle("Voxglass")
        .accessibilityIdentifier("watch.library")
        .confirmationDialog("Remove from Apple Watch?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove from Watch", role: .destructive) {
                if let book = pendingRemoval { Task { await services.removeFromWatch(book) } }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.title ?? "")
        }
    }

    // MARK: Hero (H1)

    private func heroCard(_ book: WatchBookDTO) -> some View {
        let isCurrent = services.playbackBook?.id == book.id
        let chapterIndex = services.resumeChapterIndex(for: book)
        return HStack(alignment: .center, spacing: 8) {
            Button { open(book) } label: {
                HStack(spacing: 8) {
                    WatchCoverTile(artworkKey: book.artworkKey, width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title).font(.headline).lineLimit(1)
                        Text("Ch \(chapterIndex + 1) · \(WatchTimeFormat.short(services.remainingInBook(for: book))) left")
                            .font(.caption2).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        WatchProgressHairline(fraction: services.progress(for: book))
                            .padding(.top, 3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(WatchAccessibilityID.nowPlaying)
            .accessibilityLabel(Text("Continue \(book.title), chapter \(chapterIndex + 1)"))

            Button {
                WKInterfaceDevice.current().play(.click)
                if isCurrent { services.togglePlayPause() } else { Task { await services.resume(book) } }
            } label: {
                Image(systemName: isCurrent && services.playback.isActuallyPlaying ? "pause.fill" : "play.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(WatchPalette.ink))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent && services.playback.isActuallyPlaying ? Text("Pause") : Text("Resume"))
            .accessibilityIdentifier("watch.home.heroPlay")
            .watchPrimaryActionShortcut()
        }
        .padding(10)
        .background(
            LinearGradient(colors: [Color(red: 0.48, green: 0.35, blue: 0.18), Color(red: 0.16, green: 0.12, blue: 0.09)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Empty (H3)

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "book").font(.title3).foregroundStyle(WatchPalette.accent)
            Text("No books on this watch").font(.headline).multilineTextAlignment(.center)
            Text("On iPhone, open Settings and choose books for Apple Watch.")
                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            WatchHandoffButton()
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(WatchPalette.surface))
        .accessibilityIdentifier("watch.empty.downloads")
    }

    // MARK: Footer

    private var footer: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(syncStatus).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.sync.status")
                Button { services.session.syncNow() } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!services.isConnected || services.session.isSyncing)
                .accessibilityIdentifier("watch.sync")
                if services.session.isSyncing { ProgressView().controlSize(.mini) }
            }
            .watchCardRow()
            Button { path.append(.about) } label: { Text("About") }
                .watchCardRow()
                .accessibilityIdentifier("watch.about.row")
        }
    }

    private var syncStatus: String {
        if services.session.isSyncing { return String(localized: "Syncing…") }
        if services.session.syncNeedsAttention || services.session.connectionError != nil
            || services.session.bookReports.values.contains(where: { $0.failureMessage != nil })
            || services.session.snapshot?.downloadStates?.values.contains(where: {
                if case .failed = $0 { return true }; return false
            }) == true {
            return String(localized: "Sync needs attention")
        }
        return services.isConnected ? String(localized: "iPhone connected") : String(localized: "iPhone not connected")
    }

    private func open(_ book: WatchBookDTO) {
        if services.playbackBook?.id == book.id {
            path.append(.player)
        } else {
            path.append(.book(book.id))
        }
    }

    private func watchBookAccessibilityLabel(_ book: WatchBookDTO) -> String {
        var parts = [book.title]
        if let author = book.author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(String(localized: "by \(author)"))
        }
        parts.append(services.downloaded.contains(book.id) ? String(localized: "downloaded") : String(localized: "on iPhone"))
        return parts.joined(separator: ", ")
    }
}

/// H2 row: cover · title · one status line (progress · where it lives) · a location glyph.
struct WatchBookRow: View {
    let book: WatchBookDTO
    @EnvironmentObject private var services: WatchAppServices

    var body: some View {
        HStack(spacing: 8) {
            WatchCoverTile(artworkKey: book.artworkKey, width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title).font(.body).lineLimit(1)
                Text(statusLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            if let download = services.downloads[book.id] {
                WatchTransferRing(fraction: download.total > 0 ? download.fraction : nil, size: 18)
            } else if services.downloaded.contains(book.id) {
                Image(systemName: "arrow.down.circle.fill").font(.caption2).foregroundStyle(WatchPalette.success)
            } else {
                Image(systemName: "iphone").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusLine: String {
        if let download = services.downloads[book.id] {
            return String(localized: "Downloading \(Int((download.fraction * 100).rounded()))%")
        }
        let progress = services.progress(for: book)
        let place = services.downloaded.contains(book.id) ? String(localized: "on watch") : String(localized: "iPhone")
        if progress <= 0.001 { return String(localized: "Not started · \(place)") }
        return String(localized: "\(Int((progress * 100).rounded()))% · \(place)")
    }
}

/// H3 "Continue on iPhone": Handoff to the iPhone app's My Books (`onContinueUserActivity` there).
/// The watch can't open an iPhone app directly, so the button advertises the activity and says
/// where the person must accept it. The watch can't know whether they have.
struct WatchHandoffButton: View {
    @State private var offered = false

    var body: some View {
        VStack(spacing: 4) {
            Button { offered = true } label: { Text("Continue on iPhone") }
                .buttonStyle(.watchPrimarySmall)
                .accessibilityIdentifier("watch.empty.handoff")
            if offered {
                Text("Check your iPhone")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("watch.empty.handoff.pending")
                Text("On your iPhone, open the App Switcher and tap the Voxglass banner.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("watch.empty.handoff.message")
            }
        }
        .userActivity(WatchHandoffRoute.activityType, isActive: offered) { activity in
            activity.title = String(localized: "My Books")
            activity.isEligibleForHandoff = true
        }
    }
}
