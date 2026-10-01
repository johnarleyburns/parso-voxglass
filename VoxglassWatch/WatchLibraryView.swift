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

    var body: some View {
        List {
            if let hero = services.heroBook {
                heroCard(hero)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            if services.visibleBooks.isEmpty {
                emptyCard
                    .listRowBackground(Color.clear)
            } else {
                Section("Library") {
                    ForEach(services.visibleBooks.filter { $0.id != services.heroBook?.id }, id: \.id) { book in
                        Button { open(book) } label: { WatchBookRow(book: book) }
                            .buttonStyle(.plain)
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
                if isCurrent { services.togglePlayPause() } else { services.play(book, chapterIndex: chapterIndex) }
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
            Text("On iPhone, open a book and tap Download to Apple Watch. It keeps your place.")
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
            WatchStatusChip(title: services.isConnected ? String(localized: "iPhone connected")
                                                        : String(localized: "On This Watch"),
                            tone: services.isConnected ? .good : .warning)
                .accessibilityIdentifier(WatchAccessibilityID.connection)
                .listRowBackground(Color.clear)
            if !services.downloads.isEmpty || !services.downloaded.isEmpty {
                Button { path.append(.downloads) } label: {
                    HStack {
                        Label("Downloads", systemImage: "arrow.down.circle")
                        Spacer()
                        if !services.downloads.isEmpty {
                            WatchTransferRing(fraction: aggregateDownloadFraction, size: 16)
                        }
                    }
                }
                .watchCardRow()
                .accessibilityIdentifier("watch.downloads.row")
            }
            Button { path.append(.about) } label: { Text("About") }
                .watchCardRow()
                .accessibilityIdentifier("watch.about.row")
        }
    }

    private var aggregateDownloadFraction: Double? {
        let entries = Array(services.downloads.values)
        let total = entries.reduce(0) { $0 + $1.total }
        guard total > 0 else { return nil }
        return Double(entries.reduce(0) { $0 + $1.done }) / Double(total)
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

/// H3 "Show Me on iPhone": Handoff to the iPhone app's My Books (`onContinueUserActivity` there).
/// The watch can't open an iPhone app directly, so the button advertises the activity and says
/// where to pick it up.
struct WatchHandoffButton: View {
    @State private var offered = false

    var body: some View {
        VStack(spacing: 4) {
            Button { offered = true } label: { Text("Show Me on iPhone") }
                .buttonStyle(.watchPrimarySmall)
                .accessibilityIdentifier("watch.empty.handoff")
            if offered {
                Text("Ready on your iPhone — open the App Switcher and tap Voxglass.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .userActivity("guru.parso.voxglass.watch.library", isActive: offered) { activity in
            activity.title = String(localized: "My Books")
            activity.isEligibleForHandoff = true
        }
    }
}
