import SwiftUI
import VoxglassCore

/// The Narration tab: "Start a Narration" discovery shelf (n01) plus
/// My Narrations (n03). Replaces the old home-screen shelf and the My Books
/// entry so all narration content lives on one tab.
struct NarrationTabView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @State private var flowNeed: NarrationNeed?
    @State private var showNewNarration = false
    @State private var showingNeeds = false

    var body: some View {
        NavigationStack {
            VoxglassScreen(title: "Narration") {
                VStack(alignment: .leading, spacing: 26) {
                    NarrationHomeShelf(
                        presentBrowse: { showingNeeds = true },
                        startProject: { flowNeed = $0 },
                        startNew: { showNewNarration = true },
                        showRails: !discovery.myNarrations.contains { $0.recordedCount > 0 }
                    )
                    MyNarrationsSection()
                }
                .padding(.top, 12)
            }
            .navigationDestination(isPresented: $showingNeeds) {
                NarrationNeedsView(
                    startProject: { flowNeed = $0 }
                )
            }
            .fullScreenCover(item: $flowNeed) { need in
                NarrationFlowRoot(startNeed: need)
            }
            .fullScreenCover(isPresented: $showNewNarration) {
                NarrationFlowRoot()
            }
        }
        .accessibilityIdentifier("narration.tab")
    }
}
