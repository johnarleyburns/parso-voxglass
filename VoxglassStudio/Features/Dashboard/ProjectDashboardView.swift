import SwiftUI
import VoxglassCore

/// Project Dashboard (spec §18.1.5): progress ring, review card, chapter list,
/// and the two primary actions.
public struct ProjectDashboardView: View {
    let model: ProjectDashboardModel

    @Environment(StudioEnvironment.self) private var env

    public init(model: ProjectDashboardModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                reviewCard
                chapterList
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(env.currentProject?.metadata.title ?? "Dashboard")
        .onAppear {
            Task { await model.load() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: model.counts.paragraphs == 0 ? 0 : Double(model.counts.recorded) / Double(model.counts.paragraphs))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack {
                    Text("\(model.counts.percentLabel)")
                        .font(.title2.bold())
                    Text("recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(model.counts.recorded) of \(model.counts.paragraphs) paragraphs recorded")
                    .font(.headline)
                Text("\(model.counts.flagged) flagged · \(model.counts.needsPickup) need pickup · \(model.counts.approved) approved")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        env.navigate(to: .review)
                    } label: {
                        Label("Start Review Queue", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("dashboard.startReview")

                    Button {
                        env.navigate(to: .record)
                    } label: {
                        Label("Record Next", systemImage: "record.circle")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.recordNext == nil)
                    .accessibilityIdentifier("dashboard.recordNext")

                    Button {
                        env.navigate(to: .metadata)
                    } label: {
                        Label("Metadata", systemImage: "doc.text")
                    }
                    .accessibilityIdentifier("dashboard.metadata")

                    Button {
                        env.navigate(to: .validate)
                    } label: {
                        Label("Validate", systemImage: "checkmark.seal")
                    }
                    .accessibilityIdentifier("dashboard.validate")
                }
            }
        }
    }

    private var reviewCard: some View {
        HStack(spacing: 20) {
            stat("Flagged", model.counts.flagged, color: .orange, symbol: "flag")
            stat("Needs pickup", model.counts.needsPickup, color: .red, symbol: "arrow.counterclockwise")
            stat("Unapproved", model.counts.recorded - model.counts.approved, color: .blue, symbol: "checkmark.seal")
            Spacer()
            Text("Ready to export: \(model.counts.chapters) chapters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func stat(_ label: String, _ value: Int, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(color)
                Text("\(value)").font(.title3.bold())
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chapterList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters")
                .font(.headline)
            ForEach(model.chapterRows) { row in
                HStack {
                    Text("\(row.ordinal + 1). \(row.title)")
                        .lineLimit(1)
                    Spacer()
                    ProgressView(value: row.total == 0 ? 0 : Double(row.recorded), total: Double(max(1, row.total)))
                        .frame(width: 120)
                    Text("\(row.recorded)/\(row.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }
}

extension ProjectCounts {
    var percentLabel: String {
        guard paragraphs > 0 else { return "0%" }
        return "\(Int((Double(recorded) / Double(paragraphs) * 100).rounded()))%"
    }
}
