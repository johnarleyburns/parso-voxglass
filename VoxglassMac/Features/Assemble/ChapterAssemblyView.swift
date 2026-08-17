import SwiftUI
import VoxglassCore

/// Chapter Assembly (spec §18.1.11): per-chapter segment table, spacing
/// controls, render preview, play chapter, and the render-cache summary with
/// "Rebuild Changed Audio".
public struct ChapterAssemblyView: View {
    @Bindable var model: AssemblyModel

    public init(model: AssemblyModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            spacingControls
            Divider()
            if model.isRendering {
                ProgressView("Rendering…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chapterTable
            }
            Divider()
            cacheSummary
        }
        .frame(minWidth: 860, minHeight: 480)
        .onAppear {
            Task { await model.load() }
        }
    }

    // MARK: - Spacing

    private var spacingControls: some View {
        HStack(spacing: 20) {
            Label("Spacing", systemImage: "slider.horizontal.3")
                .font(.headline)
            spacingSlider(label: "Paragraph gap", id: "assemble.paragraphGap", value: $model.settings.paragraphGap, range: 0.1...2.0)
            spacingSlider(label: "Chapter head", id: "assemble.headSilence", value: $model.settings.chapterHeadSilence, range: 0.1...3.0)
            spacingSlider(label: "Chapter tail", id: "assemble.tailSilence", value: $model.settings.chapterTailSilence, range: 0.1...5.0)
            spacingSlider(label: "Scene break extra", id: "assemble.sceneBreakGap", value: $model.settings.sceneBreakExtraGap, range: 0.0...5.0)
            Toggle("Normalize gaps", isOn: $model.settings.normalizeGapsFromTakeSilence)
                .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func spacingSlider(label: String, id: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) \(value.wrappedValue, specifier: "%.2f") s")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(width: 130)
                .accessibilityIdentifier(id)
        }
    }

    // MARK: - Table

    private var chapterTable: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.chapterStates) { chapter in
                    chapterCard(chapter)
                }
            }
            .padding(16)
        }
    }

    private func chapterCard(_ chapter: AssemblyModel.ChapterState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(chapter.ordinal + 1). \(chapter.title)")
                    .font(.headline)
                    .accessibilityIdentifier("assemble.row.\(chapter.ordinal)")
                Spacer()
                Text("\(chapter.paragraphCount) ¶ · \(formatDuration(chapter.duration))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                cacheBadge(chapter)
                Button("Render Preview") {
                    Task { await model.renderChapter(chapter.id) }
                }
                .disabled(chapter.segments.isEmpty)
                .accessibilityIdentifier("assemble.renderPreview")
                Button("Play Chapter") {
                    Task { await model.playChapter(chapter.id) }
                }
                .disabled(chapter.segments.isEmpty)
                .accessibilityIdentifier("assemble.playChapter")
            }

            if !chapter.segments.isEmpty {
                Table(of: PlaybackSegment.self) {
                    TableColumn("¶") { seg in
                        Text("#\(seg.globalOrdinal)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    TableColumn("Take") { seg in
                        Text(seg.assetRef.sha256.prefix(8))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    TableColumn("Trim") { seg in
                        Text(String(format: "%.2f–%.2f", seg.trim.lowerBound, seg.trim.upperBound))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    TableColumn("Gap") { seg in
                        Text(String(format: "%.2f s", seg.leadingSilence))
                            .font(.caption)
                            .monospacedDigit()
                    }
                    TableColumn("Status") { seg in
                        Text(statusText(seg.reviewState))
                            .font(.caption)
                            .foregroundStyle(statusColor(seg.reviewState))
                    }
                } rows: {
                    ForEach(chapter.segments) { segment in
                        TableRow(segment)
                    }
                }
                .frame(minHeight: 120)
            } else {
                Text("No recorded paragraphs in this chapter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .accessibilityIdentifier("assembly.chapter")
    }

    private func cacheBadge(_ chapter: AssemblyModel.ChapterState) -> some View {
        Text(chapter.isCached ? "Cached" : "Needs rebuild")
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(chapter.isCached ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            )
    }

    // MARK: - Summary

    private var cacheSummary: some View {
        HStack {
            Text(model.changedChapterCount == 0
                 ? "All chapters rendered"
                 : "\(model.changedChapterCount) chapter\(model.changedChapterCount == 1 ? "" : "s") require rebuilding")
                .font(.subheadline)
            Spacer()
            Button("Rebuild Changed Audio") {
                Task { await model.rebuildChanged() }
            }
            .disabled(model.changedChapterCount == 0 || model.isRendering)
            .accessibilityIdentifier("assemble.rebuildChanged")
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func statusText(_ state: ReviewState) -> String {
        switch state {
        case .flagged: return "Flagged"
        case .needsPickup: return "Needs pickup"
        case .approved: return "Approved"
        case .unreviewed: return "Unreviewed"
        }
    }

    private func statusColor(_ state: ReviewState) -> Color {
        switch state {
        case .flagged: return .orange
        case .needsPickup: return .red
        case .approved: return .green
        case .unreviewed: return .secondary
        }
    }
}
