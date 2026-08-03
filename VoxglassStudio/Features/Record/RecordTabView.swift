import SwiftUI
import VoxglassCore

/// The Record tab (spec §18.1.7): the recording workspace over the open
/// project's paragraphs. WP-C adds the takes list, accept/flag advance,
/// quality panel, and full §11.4 keyboard table.
struct RecordTabView: View {
    let project: AudiobookProject

    @Environment(StudioEnvironment.self) private var env
    @State private var paragraphIndex = 0

    var body: some View {
        let paragraphs = project.allParagraphs
        RecordingWorkspaceView(
            model: RecordingModel(
                capture: env.capture,
                store: env.store,
                assets: env.assetStoreForCurrentProject(),
                projectID: project.id,
                packageRoot: env.currentPackageRoot
            ),
            paragraph: paragraphs.isEmpty ? nil : paragraphs[paragraphIndex],
            paragraphIndex: paragraphIndex,
            totalParagraphs: paragraphs.count,
            onNavigate: { index in
                paragraphIndex = max(0, min(index, paragraphs.count - 1))
            }
        )
        .background(Color.clear.onReceive(
            NotificationCenter.default.publisher(for: .studioRecordParagraphAdvance)
        ) { notification in
            let delta = (notification.object as? Int) ?? 1
            paragraphIndex = max(0, min(paragraphIndex + delta, paragraphs.count - 1))
        })
    }
}
