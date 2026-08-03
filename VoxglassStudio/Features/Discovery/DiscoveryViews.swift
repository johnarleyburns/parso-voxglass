import SwiftUI
import VoxglassCore

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private func slug(_ title: String) -> String {
    title.lowercased()
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: "-")
}

private func shortDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "~\(seconds) sec" }
    if seconds < 3600 { return "~\(seconds / 60) min" }
    return "~\(String(format: "%.1f", Double(seconds) / 3600)) hr"
}

private func initials(_ title: String) -> String {
    title.split(separator: " ").prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
}

private struct MacSignalBadge: View {
    let signal: NeedSignal
    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
            .foregroundStyle(tint)
    }

    private var label: String {
        switch signal {
        case .openProjectNeedsReader: return "Open project · needs readers"
        case .proofListenerNeeded: return "Proof-listener needed"
        case .weeklyFeatured: return "This Week's Poem"
        case .catalogGap: return "Needs a narrator"
        case .evergreen: return "Classic"
        }
    }

    private var tint: Color {
        switch signal {
        case .openProjectNeedsReader: return Color(hex: 0x72D59F)
        case .proofListenerNeeded: return Color(hex: 0xE6B877)
        case .weeklyFeatured: return Color(hex: 0xE0BE7F)
        case .catalogGap: return Color(hex: 0xC9B6FF)
        case .evergreen: return .secondary
        }
    }
}

private struct MacGradeBadge: View {
    let grade: WorkGrade
    var body: some View {
        Text(grade == .submittable ? "Submittable" : "Practice")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(grade == .submittable ? Color(hex: 0xE0BE7F) : Color.secondary)
            .background(grade == .submittable ? Color(hex: 0xE0BE7F).opacity(0.12) : Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(grade == .submittable ? Color(hex: 0xE0BE7F).opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - n05 Library section

/// "Start a Narration" discovery section on the Studio Library (n05):
/// Book of the Month (featured, monthly, long), Short Works, Needs a Narrator.
struct NarrationSectionView: View {
    @Environment(StudioDiscoveryModel.self) private var discovery
    let browse: () -> Void
    let start: (NarrationNeed) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Start a Narration")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Browse all needs →", action: browse)
                    .buttonStyle(.link)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("needsBrowser.open")
            }
            .padding(.top, 20)

            Text("Bring a public-domain work to life. Short works or whole books — your Mac does both.")
                .font(.callout)
                .foregroundStyle(Color(hex: 0xE0BE7F))
                .italic()
                .padding(.top, 2)

            if let featured = discovery.featured {
                bookOfMonth(featured)
                    .padding(.top, 14)
            }

            rail(title: "Short Works", needs: Array(discovery.needs.filter { $0.work.lengthClass == .short }.prefix(8)), long: false)
            rail(title: "Needs a Narrator", needs: Array(discovery.needs.filter { $0.work.lengthClass == .long }.prefix(8)), long: true)
        }
        .accessibilityIdentifier("library.startNarrationSection")
        .task { await discovery.refreshOnce() }
    }

    private func bookOfMonth(_ need: NarrationNeed) -> some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [Color(hex: 0x101A14), Color(hex: 0x2F5A3E), Color(hex: 0xC7B06A)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 110, height: 150)
                .overlay(Text(initials(need.work.title)).font(.title2.weight(.heavy)).foregroundStyle(Color(hex: 0xF4E6CF)))
            VStack(alignment: .leading, spacing: 6) {
                MacSignalBadge(signal: need.signal)
                Text(need.work.title).font(.title3.weight(.semibold))
                Text("\(need.work.author) · \(shortDuration(need.work.estSeconds)) · \(LegalStrings.noCopyrightDetermination)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("One click sets up the whole book — chapters segmented, the LibriVox disclaimer inserted per chapter, and rights pre-filled from Project Gutenberg.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Start narrating ▸") { start(need) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xE0BE7F))
                    .controlSize(.large)
                    .padding(.top, 4)
                    .accessibilityIdentifier("need.startNarrating.\(slug(need.work.title))")
            }
            Spacer()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x2E2717).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0xE0BE7F).opacity(0.4), lineWidth: 1))
        .accessibilityIdentifier("library.bookOfMonth")
    }

    private func rail(title: String, needs: [NarrationNeed], long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(needs) { need in
                        card(need, long: long)
                    }
                }
            }
        }
    }

    private func card(_ need: NarrationNeed, long: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(need.work.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text("\(need.work.author) · \(shortDuration(need.work.estSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
            MacSignalBadge(signal: need.signal)
            MacGradeBadge(grade: need.work.grade)
            Button("Start narrating") { start(need) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .accessibilityIdentifier("need.startNarrating.\(slug(need.work.title))")
        }
        .padding(13)
        .frame(width: 190, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12)
                .stroke(long ? Color(hex: 0x5A6A9A) : Color(hex: 0x6F5A9A), lineWidth: 3)
                .frame(width: 4)
        }
    }
}

// MARK: - n06 Needs browser

struct NeedsBrowserView: View {
    @Environment(StudioDiscoveryModel.self) private var discovery
    let start: (NarrationNeed) -> Void
    @State private var filter: MacNeedFilter = .all
    @State private var searchText = ""

    enum MacNeedFilter: String, CaseIterable {
        case all, poems, stories, books, needsReader, first, featured
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(MacNeedFilter.allCases, id: \.self) { item in
                        Button(item.rawValue.capitalized) {
                            filter = item
                        }
                        .buttonStyle(.bordered)
                        .tint(filter == item ? Color(hex: 0xE0BE7F) : nil)
                        .accessibilityIdentifier("needsBrowser.filter.\(item.rawValue)")
                    }
                    Spacer()
                    TextField("Search works, authors, subjects…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                .padding(.top, 8)
                .accessibilityIdentifier("needsBrowser.filter")

                Text(freshnessCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("needsBrowser.freshness")

                let rows = matching
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(rows) { need in
                        browserCard(need)
                    }
                }
                Text("Sources degrade silently — if a website is unreachable or requires sign-in, this list simply shows saved works instead. \(LegalStrings.noCopyrightDetermination)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(18)
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle("Narration Needs")
        .task { await discovery.refreshOnce() }
    }

    private var freshnessCaption: String {
        switch discovery.freshness {
        case .liveEnriched: return "Updated just now · sources: bundled · parso.guru · Gutenberg · Internet Archive · LibriVox"
        case .cached: return "Showing saved works"
        case .seedOnly: return "Offline · showing saved works"
        }
    }

    private var matching: [NarrationNeed] {
        var needs = discovery.needs
        switch filter {
        case .all: break
        case .poems: needs = needs.filter { $0.work.subject?.lowercased() == "poem" }
        case .stories: needs = needs.filter { $0.work.subject?.lowercased() == "story" || $0.work.subject?.lowercased() == "essay" }
        case .books: needs = needs.filter { $0.work.lengthClass == .long }
        case .needsReader: needs = needs.filter { $0.signal == .openProjectNeedsReader || $0.signal == .proofListenerNeeded }
        case .first: needs = needs.filter { $0.signal == .catalogGap }
        case .featured: needs = needs.filter { $0.signal == .weeklyFeatured }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            needs = needs.filter { need in
                need.work.title.lowercased().contains(query)
                    || need.work.author.lowercased().contains(query)
                    || (need.work.subject ?? "").lowercased().contains(query)
            }
        }
        return needs
    }

    private func browserCard(_ need: NarrationNeed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(need.work.title).font(.headline).lineLimit(2)
            Text("\(need.work.author) · \(shortDuration(need.work.estSeconds)) · \(need.work.lengthClass == .short ? "poem/short work" : "book")")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                MacSignalBadge(signal: need.signal)
                MacGradeBadge(grade: need.work.grade)
            }
            Text("Source: \(need.work.sourcePageURL?.host ?? "bundled seed"). \(LegalStrings.noCopyrightDetermination)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("Start narrating") { start(need) }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: 0xE0BE7F))
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .accessibilityIdentifier("need.startNarrating.\(slug(need.work.title))")
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .accessibilityIdentifier("needs.card.\(slug(need.work.title))")
    }
}
