import SwiftUI
import VoxglassCore

/// Script Editor (spec §18.1.6, mockup `05-script-editor`): chapter list,
/// paragraph list with state chips, and inline text editing.
struct ScriptEditorView: View {
    @Environment(StudioEnvironment.self) private var env
    @Bindable var model: ScriptEditorModel

    var body: some View {
        HStack(spacing: 0) {
            chapterList
            Divider()
            paragraphList
        }
        .frame(minWidth: 700, minHeight: 400)
        .task { await model.load() }
        .toolbar {
            if model.isSaving {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var chapterList: some View {
        List(selection: Binding(
            get: { model.selectedChapterID },
            set: { id in
                guard let id else { return }
                Task { await model.selectChapter(id) }
            }
        )) {
            Section("Chapters") {
                ForEach(model.project.chapters) { chapter in
                    Text(chapter.title)
                        .tag(Optional(chapter.id))
                }
            }
        }
        .frame(minWidth: 200, idealWidth: 240)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }

    private var paragraphList: some View {
        ScrollViewReader { proxy in
            List(Array(model.summaries.enumerated()), id: \.element.id) { index, summary in
                paragraphRow(summary, index: index)
                    .id(summary.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paragraphRow(_ summary: ParagraphSummary, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("¶ \(summary.ordinal + 1)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                stateChip(summary)
                Spacer()
                Text(durationText(summary))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            TextField("Paragraph text", text: Binding(
                get: { model.paragraphText(summary.id) },
                set: { model.updateText(paragraphID: summary.id, text: $0) }
            ), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .disabled(isGenerated(summary.id))
            .lineLimit(1...6)
            .accessibilityIdentifier("script.paragraph.\(index)")

            if isGenerated(summary.id) {
                Label("Generated", systemImage: "wand.and.stars")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("script.generated.\(index)")
            }
        }
        .padding(.vertical, 4)
    }

    private func isGenerated(_ id: UUID) -> Bool {
        guard let role = model.roles[id] else { return false }
        switch role {
        case .libriVoxIntro, .libriVoxOutro, .retailOpeningCredits, .retailClosingCredits:
            return true
        case .body, .chapterHeading:
            return false
        }
    }

    @ViewBuilder
    private func stateChip(_ summary: ParagraphSummary) -> some View {
        let (label, color): (String, Color) = {
            if summary.hasSelectedTake {
                return ("Recorded", .green)
            }
            if summary.isTextDrifted {
                return ("Text changed", .orange)
            }
            if summary.reviewState == .needsPickup {
                return ("Needs pickup", .red)
            }
            return ("Unrecorded", .secondary)
        }()
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func durationText(_ summary: ParagraphSummary) -> String {
        guard let duration = summary.duration else { return "" }
        return String(format: "%.0fs", duration)
    }
}
