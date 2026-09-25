import SwiftUI
import VoxglassCore

/// The Narration tab: "Start a Narration" discovery shelf (n01) plus
/// My Narrations (n03). Replaces the old home-screen shelf and the My Books
/// entry so all narration content lives on one tab.
struct NarrationTabView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var flowNeed: NarrationNeed?
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
            VoxglassScreen(title: "Narrate", headerSecondaryActionTitle: "+", headerSecondaryAction: { showNewNarration = true }, headerSecondaryActionAccessibilityLabel: "Start a narration") {
                VStack(alignment: .leading, spacing: 26) {
                    NarrationStudioHero(project: discovery.myNarrations.first(where: { !$0.isReady }), start: { showNewNarration = true })
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
        }
        .accessibilityIdentifier("narration.tab")
    }

    private var compactFlowHost: some View {
        narrationContent
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
    let start: () -> Void

    var body: some View {
        if let project {
            let phase = project.phase
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CoverPlate(title: project.metadata.title, author: project.metadata.author, coverURL: nil, size: 62, shape: .portrait)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next: \(phase.label)").voxType(.eyebrow).foregroundStyle(Palette.brass)
                        Text(project.metadata.title).voxType(.bookTitle).foregroundStyle(Palette.ink).lineLimit(2)
                        Text("\(project.metadata.author) · \(project.totalCount) paragraphs").voxType(.meta).foregroundStyle(Palette.ink2).lineLimit(1)
                    }
                }
                PipelineBar(phase: phase)
                Button(phase.label == "Review" ? "Review \(project.recordedCount) takes" : "Record next paragraph", action: start)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.brass)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("narration.studio.nextStep")
            }
            .padding(16)
            .raisedSurface(tint: NarrationPalette.olive)
            .accessibilityIdentifier("narration.studio.hero")
        }
    }
}

private struct NeedsPreview: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    let limit: Int
    let startProject: (NarrationNeed) -> Void
    let seeAll: () -> Void

    var body: some View {
        let needs = Array(NarrationHomeShelfPlan(needs: discovery.availableNeeds, featured: discovery.availableFeatured).short.prefix(limit))
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Waiting for a reader", actionTitle: "See all", action: seeAll, actionIdentifier: "narration.needsSeeAll")
            ForEach(needs) { need in
                HStack(spacing: 10) {
                    CoverPlate(title: need.work.title, author: need.work.author, coverURL: nil, size: 40, shape: .portrait)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(need.work.title).voxType(.bookTitle).foregroundStyle(Palette.ink).lineLimit(1)
                        Text("\(need.work.lengthClass == .short ? "Short work" : "Group project") · about \(max(1, need.work.estSeconds / 60)) min").voxType(.meta).foregroundStyle(Palette.ink2)
                    }
                    Spacer()
                    Button("Start") { startProject(need) }
                        .buttonStyle(.glassProminent)
                        .tint(Palette.brass)
                        .accessibilityIdentifier("need.startNarrating.\(needSlug(need))")
                }
                .padding(10)
                .raisedSurface(radius: Radius.tile)
            }
        }
        .accessibilityIdentifier("narration.needsPreview")
        .task { await discovery.refreshOnce() }
    }
}
