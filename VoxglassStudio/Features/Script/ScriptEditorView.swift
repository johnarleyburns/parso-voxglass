import SwiftUI
import VoxglassCore

/// Script Editor (spec §18.1.6, mockup `05-script-editor`): chapter list,
/// paragraph list with state chips, inline text editing, drift banner, split
/// and merge, and ⌘F find.
struct ScriptEditorView: View {
    @Environment(StudioEnvironment.self) private var env
    @Bindable var model: ScriptEditorModel

    @State private var showFind = false
    @State private var keptDrift: Set<UUID> = []

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
            Button(action: { showFind.toggle() }) {
                Image(systemName: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: [.command])
            .accessibilityIdentifier("script.find")
        }
        .safeAreaInset(edge: .top) {
            if showFind {
                findBar
            }
        }
    }

    // MARK: - Find bar

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Find", text: Binding(
                get: { model.searchQuery },
                set: { model.searchQuery = $0; model.runSearch() }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .accessibilityIdentifier("script.findField")
            Text("\(model.searchMatches.isEmpty ? 0 : model.searchIndex + 1)/\(model.searchMatches.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button(action: { if let id = model.previousMatch() { scrollTo(id) } }) {
                Image(systemName: "chevron.up")
            }
            Button(action: { if let id = model.nextMatch() { scrollTo(id) } }) {
                Image(systemName: "chevron.down")
            }
            Spacer()
            Button("Done") { showFind = false }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func scrollTo(_ id: UUID) {
        NotificationCenter.default.post(name: .scriptScrollToParagraph, object: id)
    }

    // MARK: - Chapter list

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

    // MARK: - Paragraph list

    private var paragraphList: some View {
        ScrollViewReader { proxy in
            List(Array(model.summaries.enumerated()), id: \.element.id) { index, summary in
                paragraphRow(summary, index: index)
                    .id(summary.id)
            }
            .onReceive(NotificationCenter.default.publisher(for: .scriptScrollToParagraph)) { note in
                if let id = note.object as? UUID {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paragraphRow(_ summary: ParagraphSummary, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("¶ \(summary.globalOrdinal + 1)")
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
            .disabled(!model.isEditable(summary.id))
            .lineLimit(1...6)
            .accessibilityIdentifier("script.paragraph.\(index)")

            if model.isGenerated(summary.id) {
                HStack {
                    Label("Generated", systemImage: "wand.and.stars")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    if !model.isEditable(summary.id) {
                        Button("Edit anyway") {
                            model.confirmEditAnyway(summary.id)
                        }
                        .font(.caption2)
                    }
                }
                .accessibilityIdentifier("script.generated.\(index)")
            }

            if driftKind(summary.id).showsBanner && !keptDrift.contains(summary.id) {
                driftBanner(summary, index: index)
            }

            HStack(spacing: 12) {
                Button("Split") {
                    let text = model.paragraphText(summary.id)
                    Task { await model.split(paragraphID: summary.id, atCharacterOffset: text.count / 2) }
                }
                .font(.caption2)
                .accessibilityIdentifier("script.split.\(index)")

                Button("Merge") {
                    Task { await model.merge(paragraphID: summary.id) }
                }
                .font(.caption2)
                .accessibilityIdentifier("script.merge.\(index)")
            }
        }
        .padding(.vertical, 4)
        .highlight(isMatch: model.currentMatch == summary.id)
    }

    private func driftKind(_ id: UUID) -> DriftKind {
        model.driftKind(for: id)
    }

    private func driftBanner(_ summary: ParagraphSummary, index: Int) -> some View {
        HStack(spacing: 10) {
            Label("Text changed since this take was recorded", systemImage: "exclamationmark.triangle")
                .font(.caption2.weight(.medium))
                .foregroundStyle(driftKind(summary.id) == .semantic ? .red : .orange)
            Spacer()
            Button("Re-record") {
                NotificationCenter.default.post(name: .studioRecordParagraph, object: summary.id)
            }
            .font(.caption2)
            Button("Keep take") {
                keptDrift.insert(summary.id)
            }
            .font(.caption2)
        }
        .padding(6)
        .background((driftKind(summary.id) == .semantic ? Color.red : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("script.driftBanner.\(index)")
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

private extension DriftKind {
    var showsBanner: Bool {
        self == .minor || self == .semantic
    }
}

private extension View {
    func highlight(isMatch: Bool) -> some View {
        self.background(isMatch ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

extension Notification.Name {
    static let scriptScrollToParagraph = Notification.Name("script.scrollToParagraph")
    static let studioRecordParagraph = Notification.Name("studio.recordParagraph")
}
