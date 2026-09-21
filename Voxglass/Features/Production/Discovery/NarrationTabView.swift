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
            VoxglassScreen(title: "Narration") {
                VStack(alignment: .leading, spacing: 26) {
                    if discovery.myNarrations.contains(where: { $0.recordedCount > 0 }) {
                        MyNarrationsSection()
                    }
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
    }
}
