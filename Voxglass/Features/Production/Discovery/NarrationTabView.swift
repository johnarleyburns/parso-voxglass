import SwiftUI
import VoxglassCore

/// The Narration tab: "Start a Narration" discovery shelf (n01) plus
/// My Narrations (n03). Replaces the old home-screen shelf and the My Books
/// entry so all narration content lives on one tab.
struct NarrationTabView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var flowNeed: NarrationNeed?
    @State private var resumeProject: AudiobookProject?
    @State private var showNewNarration = false
    @State private var showAllNeeds = false

    var body: some View {
        if usesRegularSurface {
            regularFlowHost
        } else {
            compactFlowHost
        }
    }

    private var usesRegularSurface: Bool {
        VoxglassPlatform.isMacCatalyst || horizontalSizeClass == .regular
    }

    private var narrationContent: some View {
        NavigationStack {
            VoxglassScreen(title: "Narrate", embedsNavigationStack: false, headerSecondaryActionSystemImage: "plus", headerSecondaryAction: { showNewNarration = true }, headerSecondaryActionAccessibilityLabel: "Start a narration") {
                VStack(alignment: .leading, spacing: 26) {
                    NarrationStudioHero(
                        project: discovery.myNarrations.first(where: { !$0.isReady }),
                        availableNeedCount: discovery.availableNeeds.count,
                        start: { showNewNarration = true },
                        resume: { resumeProject = $0 },
                        findBook: { showAllNeeds = true }
                    )
                    if discovery.myNarrations.contains(where: { $0.recordedCount > 0 }) {
                        MyNarrationsSection()
                    }
                    NeedsPreview(limit: 3, startProject: { flowNeed = $0 }, seeAll: { showAllNeeds = true })
                    NarrationHomeShelf(
                        startProject: { flowNeed = $0 },
                        startNew: { showNewNarration = true },
                        showRails: !discovery.myNarrations.contains { $0.recordedCount > 0 }
                    )
                }
                .padding(.top, 12)
            }
            .refreshable { await discovery.refreshOnce() }
        }
        .accessibilityIdentifier("narration.tab")
    }

    private func resumeStep(for project: AudiobookProject) -> NarrationStep? {
        if case .review = project.phase { return .reviewList }
        return nil
    }

    private var compactFlowHost: some View {
        narrationContent
            .fullScreenCover(item: $resumeProject) { project in
                NarrationFlowRoot(existingID: project.id, startAt: resumeStep(for: project))
            }
            .fullScreenCover(item: $flowNeed) { need in
                NarrationFlowRoot(startNeed: need)
            }
            .fullScreenCover(isPresented: $showNewNarration) {
                NarrationFlowRoot()
            }
            .sheet(isPresented: $showAllNeeds) {
                NavigationStack {
                    NarrationNeedsView(startProject: { need in
                        showAllNeeds = false
                        flowNeed = need
                    })
                }
            }
    }

    private var regularFlowHost: some View {
        narrationContent
            .sheet(item: $resumeProject) { project in
                NarrationFlowRoot(existingID: project.id, startAt: resumeStep(for: project))
                    .frame(minWidth: 720, minHeight: 600)
            }
            .sheet(item: $flowNeed) { need in
                NarrationFlowRoot(startNeed: need)
                    .frame(minWidth: 720, minHeight: 600)
            }
            .sheet(isPresented: $showNewNarration) {
                NarrationFlowRoot()
                    .frame(minWidth: 720, minHeight: 600)
            }
            .sheet(isPresented: $showAllNeeds) {
                NavigationStack {
                    NarrationNeedsView(startProject: { need in
                        showAllNeeds = false
                        flowNeed = need
                    })
                }
            }
    }
}

private struct NarrationStudioHero: View {
    let project: AudiobookProject?
    let availableNeedCount: Int
    let start: () -> Void
    let resume: (AudiobookProject) -> Void
    let findBook: () -> Void

    var body: some View {
        if let project {
            let phase = project.phase
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CoverPlate(title: project.metadata.title, author: project.metadata.author, coverURL: nil, size: 62, shape: .portrait)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next: \(phase.label)").voxType(.eyebrow).foregroundStyle(Palette.brass)
                        Text(project.metadata.title).voxType(.bookTitle).foregroundStyle(Palette.ink).lineLimit(2)
                        Text("\(project.metadata.author) · \(project.totalCount) paragraphs").voxType(.meta).foregroundStyle(Palette.ink2)
                    }
                }
                PipelineBar(phase: phase)
                switch phase {
                case .review:
                    Button("Review \(project.recordedCount) takes") { resume(project) }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.brass)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("narration.studio.nextStep")
                default:
                    Button("Record next paragraph") { resume(project) }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.brass)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("narration.studio.nextStep")
                }
            }
            .padding(16)
            .raisedSurface(tint: NarrationPalette.olive)
            .accessibilityIdentifier("narration.studio.hero")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("LIBRIVOX VOLUNTEERS").voxType(.eyebrow).foregroundStyle(Palette.brass)
                Text("Give a book its voice").voxType(.heroTitle).foregroundStyle(Palette.ink)
                if availableNeedCount > 0 {
                    Text("\(availableNeedCount) public-domain works are waiting for a reader. Record a chapter in 20 minutes and it joins the free LibriVox catalog, for anyone, forever.")
                        .voxType(.body).foregroundStyle(Palette.ink2)
                } else {
                    Text("Choose a public-domain work to read, or preview your own narration privately before you submit it.")
                        .voxType(.body).foregroundStyle(Palette.ink2)
                }
                Button("Find a book to read", action: findBook)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.brass)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("narration.hero.findBook")
                Button("Narrate your own text", action: start)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.brass)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("narration.hero.ownText")
            }
            .padding(16)
            .raisedSurface(tint: NarrationPalette.olive)
            .accessibilityIdentifier("narration.hero.empty")
        }
    }
}

private struct NeedsPreview: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    let limit: Int
    let startProject: (NarrationNeed) -> Void
    let seeAll: () -> Void

    var body: some View {
        let needs = Array(discovery.availableNeeds.prefix(limit))
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Waiting for a narrator", actionTitle: "See all", action: seeAll, actionIdentifier: "narration.needsSeeAll")
            if needs.isEmpty {
                Text("No verified open LibriVox projects are available right now. Pull to refresh to check again.")
                    .voxType(.body).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(needs) { need in
                HStack(spacing: 10) {
                    CoverPlate(title: need.work.title, author: need.work.author, coverURL: nil, size: 40, shape: .portrait)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(need.work.title).voxType(.bookTitle).foregroundStyle(Palette.ink)
                        Text("\(need.work.lengthClass == .short ? "Short work" : "Group project") · about \(max(1, need.work.estSeconds / 60)) min").voxType(.meta).foregroundStyle(Palette.ink2) // l10n-exempt: state-dependent accessibility or status copy
                    }
                    Spacer()
                    NeedAction(need: need, startProject: startProject)
                }
                .padding(10)
                .raisedSurface(radius: Radius.tile)
            }
        }
        .accessibilityIdentifier("narration.needsPreview")
        .task { await discovery.refreshOnce() }
    }
}
