import SwiftUI
import VoxglassCore

/// The Narration tab: "Start a Narration" discovery shelf (n01) plus
/// My Narrations (n03). Replaces the old home-screen shelf and the My Books
/// entry so all narration content lives on one tab.
struct NarrationTabView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @State private var flowNeed: NarrationNeed?
    @State private var handoffNeed: NarrationNeed?
    @State private var showingNeeds = false
    @State private var findSomething = false

    var body: some View {
        VoxglassScreen(title: "Narration") {
            VStack(alignment: .leading, spacing: 26) {
                NarrationHomeShelf(
                    presentBrowse: { showingNeeds = true },
                    startProject: { flowNeed = $0 },
                    presentHandoff: { handoffNeed = $0 }
                )
                MyNarrationsSection(findSomething: { findSomething = true })
            }
            .padding(.top, 12)
        }
        .navigationDestination(isPresented: $showingNeeds) {
            NarrationNeedsView(
                startProject: { flowNeed = $0 },
                presentHandoff: { handoffNeed = $0 }
            )
        }
        .fullScreenCover(item: $flowNeed) { need in
            NarrationFlowRoot(startNeed: need)
        }
        .sheet(item: $handoffNeed) { need in
            LongWorkHandoffSheet(need: need)
        }
        .fullScreenCover(isPresented: $findSomething) {
            NarrationFlowRoot(startNeed: nil)
        }
        .accessibilityIdentifier("narration.tab")
    }
}
