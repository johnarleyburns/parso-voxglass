import SwiftUI
import VoxglassCore

// MARK: - Signal / grade badges

struct SignalBadge: View {
    let signal: NeedSignal
    var body: some View {
        Text(label)
            .scaledFont(size: 10, weight: .bold)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
            .foregroundStyle(tint)
    }

    private var label: String {
        switch signal {
        case .openProjectNeedsReader: return "Open project · needs a reader"
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
        case .weeklyFeatured: return Palette.brass
        case .catalogGap: return Color(hex: 0xC9B6FF)
        case .evergreen: return Palette.ink3
        }
    }
}

struct GradeBadge: View {
    let grade: WorkGrade
    var body: some View {
        Text(grade == .submittable ? "Submittable" : "Practice")
            .scaledFont(size: 10, weight: .bold)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(grade == .submittable ? Palette.brass : Palette.ink3)
            .background(grade == .submittable ? Palette.brass.opacity(0.12) : Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(grade == .submittable ? Palette.brass.opacity(0.5) : Palette.hairline, lineWidth: 1))
    }
}

func needSlug(_ need: NarrationNeed) -> String {
    need.work.title
        .lowercased()
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .joined(separator: "-")
}

func shortDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "~\(seconds) sec" }
    if seconds < 3600 { return "~\(seconds / 60) min" }
    return "~\(String(format: "%.1f", Double(seconds) / 3600)) hr"
}

extension TimeInterval {
    /// "1 min 11 sec" style caption used by My Narrations rows.
    var formattedShort: String {
        let total = Int(self)
        let minutes = total / 60
        let seconds = total % 60
        if minutes == 0 { return "\(seconds) sec" }
        return "\(minutes) min \(seconds) sec"
    }
}

// MARK: - n01 Home shelf

/// "Start a Narration" shelf appended below Recommended on the listening home
/// (n01): This Week's Poem + short rail + long rail.
struct NarrationHomeShelf: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    let presentBrowse: () -> Void
    let startProject: (NarrationNeed) -> Void
    let presentHandoff: (NarrationNeed) -> Void

    var body: some View {
        // NOTE: no accessibilityIdentifier on this container — a plain VStack
        // with one overrides every child's identifier (SwiftUI quirk), which
        // would make `needs.featured` / rail CTAs unreachable from UI tests.
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Start a Narration", actionTitle: "See All", action: presentBrowse)
                .accessibilityIdentifier("home.startNarrationShelf")

            Text("Lend your voice to the public domain.")
                .scaledFont(size: 12.5)
                .foregroundStyle(Palette.ink2)
                .italic()

            if let featured = discovery.featured {
                featuredCard(featured)
                    .padding(.top, 12)
            }

            if !discovery.needs.filter { $0.work.lengthClass == .short }.isEmpty {
                shortRail
            }
            if !discovery.needs.filter { $0.work.lengthClass == .long }.isEmpty {
                longRail
            }
        }
        .task { await discovery.refreshOnce() }
    }

    @ViewBuilder
    private func featuredCard(_ need: NarrationNeed) -> some View {
        let actionable = need.narratableOn.contains(.iOS)
        Button {
            if actionable { startProject(need) } else { presentHandoff(need) }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [Color(hex: 0x3A2F1C), Color(hex: 0x6B5432)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("🎙️").scaledFont(size: 26)
                }
                .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        GradeBadge(grade: need.work.grade)
                        Text("Public domain · US").scaledFont(size: 10).foregroundStyle(Palette.ink3)
                    }
                    Text(need.work.title)
                        .scaledFont(size: 16, weight: .heavy)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                    Text("\(need.work.author) · \(shortDuration(need.work.estSeconds)) · one tap to record")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Palette.brass)
            }
            .padding(14)
            .glassSurface(cornerRadius: 20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Palette.brass.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tactileTap()
        .accessibilityIdentifier("needs.featured")
    }

    private var shortRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Short Works to Narrate", actionTitle: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(discovery.needs.filter { $0.work.lengthClass == .short }.prefix(12)) { need in
                        ShortNeedCard(need: need, start: { startProject(need) })
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .accessibilityIdentifier("needs.rail.short")
    }

    private var longRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "More on Your Mac", actionTitle: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(discovery.needs.filter { $0.work.lengthClass == .long }.prefix(10)) { need in
                        LongNeedCard(need: need, presentHandoff: { presentHandoff(need) })
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .accessibilityIdentifier("needs.rail.long")
    }
}

// MARK: - Short need card

struct ShortNeedCard: View {
    let need: NarrationNeed
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(need.work.title)
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(need.work.author) · \(shortDuration(need.work.estSeconds))")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink2)
                .padding(.top, 2)
            GradeBadge(grade: need.work.grade)
                .padding(.top, 8)
            Button(action: start) {
                Text("Start narrating")
                    .scaledFont(size: 12, weight: .heavy)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Color(hex: 0x21170B))
            }
            .buttonStyle(.plain)
            .tactileTap()
            .padding(.top, 10)
            .accessibilityIdentifier("need.startNarrating.\(needSlug(need))")
        }
        .padding(12)
        .frame(width: 150, alignment: .leading)
        .glassSurface(cornerRadius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - Long need card (handoff only, no record CTA — G-15)

struct LongNeedCard: View {
    let need: NarrationNeed
    let presentHandoff: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(hex: 0x101A14), Color(hex: 0x2F5A3E)], startPoint: .top, endPoint: .bottom))
                Text(initials(need.work.title))
                    .scaledFont(size: 14, weight: .heavy)
                    .foregroundStyle(Color(hex: 0xF8E8C7))
            }
            .frame(width: 88, height: 118)
            Text(need.work.title)
                .scaledFont(size: 11.5, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(need.work.author)
                .scaledFont(size: 10)
                .foregroundStyle(Palette.ink3)
                .lineLimit(1)
            Button(action: presentHandoff) {
                Text("Record on Mac")
                    .scaledFont(size: 10, weight: .bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(Color(hex: 0xA9C3FF))
                    .background(Color(hex: 0x7896DC).opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color(hex: 0x7896DC).opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("need.recordOnMac.\(needSlug(need))")
        }
        .frame(width: 118)
    }

    private func initials(_ title: String) -> String {
        title.split(separator: " ").prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
    }
}

// MARK: - n02 Narration Needs browse

enum NeedFilter: String, CaseIterable, Identifiable {
    case all, poems, stories, featured, needsReader
    var id: String { rawValue }

    func matches(_ need: NarrationNeed) -> Bool {
        switch self {
        case .all: return true
        case .poems: return need.work.subject?.lowercased() == "poem"
        case .stories: return need.work.subject?.lowercased() == "story" || need.work.subject?.lowercased() == "essay"
        case .featured: return need.signal == .weeklyFeatured
        case .needsReader: return need.signal == .openProjectNeedsReader || need.signal == .proofListenerNeeded
        }
    }
}

struct NarrationNeedsView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @State private var filter: NeedFilter = .all
    let startProject: (NarrationNeed) -> Void
    let presentHandoff: (NarrationNeed) -> Void

    var body: some View {
        VoxglassScreen(title: "Narration Needs") {
            VStack(alignment: .leading, spacing: 14) {
                freshnessCaption

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(NeedFilter.allCases) { item in
                            Button {
                                filter = item
                            } label: {
                                Text(item.rawValue.capitalized)
                                    .scaledFont(size: 11, weight: item == filter ? .heavy : .semibold)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .foregroundStyle(item == filter ? Color(hex: 0x111111) : Palette.ink2)
                                    .background(item == filter ? Color(hex: 0xF6F2EA) : Color.white.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .accessibilityIdentifier("needs.filter")

                let rows = discovery.needs.filter(filter.matches)
                if rows.isEmpty {
                    EmptyStatePanel(
                        title: "Nothing Here Yet",
                        message: "Saved public-domain works will appear here.",
                        systemImage: "quote.opening"
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows.prefix(40)) { need in
                            NeedRow(need: need, startProject: startProject, presentHandoff: presentHandoff)
                            VoxglassListDivider()
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .task { await discovery.refreshOnce() }
    }

    @ViewBuilder
    private var freshnessCaption: some View {
        if discovery.freshness == .seedOnly {
            Text("Offline · showing saved works")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
        } else {
            Text(liveCaption)
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
        }
    }

    private var liveCaption: String {
        switch discovery.freshness {
        case .liveEnriched: return "Updated just now · live sources"
        case .cached: return "Showing saved works"
        case .seedOnly: return "Offline · showing saved works"
        }
    }
}

struct NeedRow: View {
    let need: NarrationNeed
    let startProject: (NarrationNeed) -> Void
    let presentHandoff: (NarrationNeed) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(hex: 0x2A2417), Color(hex: 0x5A4A2B)], startPoint: .top, endPoint: .bottom))
                Text(need.work.lengthClass == .short ? "📜" : "📕")
                    .scaledFont(size: 18)
            }
            .frame(width: 44, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(need.work.title)
                    .scaledFont(size: 14.5, weight: .bold)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(need.work.author) · \(shortDuration(need.work.estSeconds))")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    SignalBadge(signal: need.signal)
                    GradeBadge(grade: need.work.grade)
                }
            }

            Spacer(minLength: 8)

            Button {
                if need.narratableOn.contains(.iOS) {
                    startProject(need)
                } else {
                    presentHandoff(need)
                }
            } label: {
                Text(need.narratableOn.contains(.iOS) ? "Start" : "On Mac")
                    .scaledFont(size: 12, weight: .heavy)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(need.narratableOn.contains(.iOS) ? Color(hex: 0x21170B) : Color(hex: 0xA9C3FF))
                    .background(need.narratableOn.contains(.iOS)
                        ? AnyShapeStyle(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(Color.clear))
                    .overlay(need.narratableOn.contains(.iOS)
                        ? nil
                        : RoundedRectangle(cornerRadius: 11).stroke(Color(hex: 0x7896DC).opacity(0.45), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
            .tactileTap()
            .accessibilityIdentifier(need.narratableOn.contains(.iOS)
                ? "need.startNarrating.\(needSlug(need))"
                : "need.recordOnMac.\(needSlug(need))")
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier("needs.card.\(needSlug(need))")
    }
}

// MARK: - n03 My Narrations

struct MyNarrationsView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    let findSomething: () -> Void

    var body: some View {
        VoxglassScreen(title: "My Narrations") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Short works you're recording. Whole books → Voxglass Studio on your Mac.")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ink2)

                Button(action: findSomething) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                        Text("Find something to narrate")
                    }
                    .scaledFont(size: 14, weight: .heavy)
                    .foregroundStyle(Palette.brass)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Palette.brass.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.brass.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }
                .buttonStyle(.plain)
                .tactileTap()
                .accessibilityIdentifier("myNarrations.newFromNeed")

                let projects = discovery.myNarrations
                if projects.isEmpty {
                    EmptyStatePanel(
                        title: "No Narrations Yet",
                        message: "Find a poem or short work and record it right here.",
                        systemImage: "mic"
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(projects) { project in
                            NavigationLink {
                                NarrationFlowRoot(existing: project)
                            } label: {
                                projectRow(project)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("myNarrations.project.\(needSlugFromTitle(project.title))")
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .accessibilityIdentifier("myNarrations.list")
        .onAppear { discovery.reloadNarrations() }
    }

    private func projectRow(_ project: NarrationProject) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(hex: 0x2A2417), Color(hex: 0x5A4A2B)], startPoint: .top, endPoint: .bottom))
                Text("🎙️").scaledFont(size: 18)
            }
            .frame(width: 46, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .scaledFont(size: 14.5, weight: .bold)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(project.author) · \(project.paragraphs.count) ¶ · ~\(project.duration(of: project.paragraphs).formattedShort)")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(LinearGradient(colors: [Palette.brass, Palette.brass.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * project.percent)
                    }
                }
                .frame(height: 6)

                Text(project.statusCaption)
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 4)
            statusPill(project)
        }
        .padding(13)
        .glassSurface(cornerRadius: 16)
    }

    @ViewBuilder
    private func statusPill(_ project: NarrationProject) -> some View {
        let (text, tint) = project.statusPill
        Text(text)
            .scaledFont(size: 11, weight: .bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }

    private func needSlugFromTitle(_ title: String) -> String {
        title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }
}

private extension NarrationProject {
    var percent: Double {
        guard !paragraphs.isEmpty else { return 0 }
        return Double(recordedCount) / Double(paragraphs.count)
    }

    var statusCaption: String {
        if approvedCount == paragraphs.count && !paragraphs.isEmpty { return "LibriVox package ready" }
        if recordedCount > 0 { return "\(recordedCount) of \(paragraphs.count) paragraphs recorded" }
        return "Draft — disclaimer & rights ready"
    }

    var statusPill: (String, Color) {
        if approvedCount == paragraphs.count && !paragraphs.isEmpty { return ("Ready", Color(hex: 0x72D59F)) }
        if recordedCount > 0 { return ("Recording", Palette.brass) }
        return ("Draft", Palette.ink3)
    }
}

// MARK: - n04 Long-work handoff

struct LongWorkHandoffSheet: View {
    let need: NarrationNeed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(colors: [Color(hex: 0x101A14), Color(hex: 0x2F5A3E), Color(hex: 0xC7B06A)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(need.work.title.uppercased())
                        .scaledFont(size: 14, weight: .heavy)
                        .foregroundStyle(Color(hex: 0xF8E8C7))
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
                .frame(width: 120, height: 160)

                Text(need.work.title)
                    .scaledFont(size: 21, weight: .heavy)
                    .foregroundStyle(Palette.ink)
                    .padding(.top, 14)
                Text("\(need.work.author) · \(shortDuration(need.work.estSeconds)) · a full book")
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.ink2)
                    .padding(.top, 2)

                Text("This is a **book** — best recorded on a Mac, where you get chapter-by-chapter recording, faster review, and a good microphone. Your iPhone is perfect for short poems and stories.")
                    .scaledFont(size: 13.5)
                    .multilineTextAlignment(.center)
                    .padding(15)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
                    .padding(.top, 12)

                steps

                Spacer()

                Button {
                    // Open the Studio Learn More deep link when available.
                } label: {
                    Text("How Voxglass Studio works")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .buttonStyle(.plain)
                .tactileTap()
                .accessibilityIdentifier("handoff.continueOnMac")

                Button {
                    dismiss()
                } label: {
                    Text("Find a short work instead")
                        .scaledFont(size: 14, weight: .bold)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("handoff.dismiss")

                Text(LegalStrings.noCopyrightDetermination)
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
            }
            .padding(24)
            .background(VoxglassBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("handoff.title")
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 10) {
            step(1, "Open Voxglass Studio on your Mac.")
            step(2, "Find \"\(need.work.title)\" under Start a Narration → Needs a Narrator — one click sets up the whole book.")
            step(3, "Record it there. A short work you started on your phone opens on the Mac too — same project.")
        }
        .padding(.top, 8)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .scaledFont(size: 12, weight: .heavy)
                .foregroundStyle(Palette.brass)
                .frame(width: 22, height: 22)
                .background(Palette.brass.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(Palette.brass.opacity(0.4), lineWidth: 1))
            Text(LocalizedStringKey(text))
                .scaledFont(size: 13)
                .foregroundStyle(Palette.ink)
        }
    }
}
