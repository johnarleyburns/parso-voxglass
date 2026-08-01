import SwiftUI
import VoxglassCore

/// Review Queue (spec §18.1.10): queue rail with state glyphs, current
/// paragraph text, transport, the three primary actions, and a local note
/// field.
public struct ReviewQueueView: View {
    @Bindable var model: ReviewQueueModel

    public init(model: ReviewQueueModel) {
        _model = Bindable(model)
    }

    public var body: some View {
        HStack(spacing: 0) {
            queueRail
            Divider()
            mainPanel
        }
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            Task { await model.load(predicate: model.predicate) }
        }
    }

    // MARK: - Queue rail

    private var queueRail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index)
                            .id(item.id)
                            .onTapGesture {
                                guard index != model.currentIndex else { return }
                                Task { await moveTo(index) }
                            }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.currentIndex) { _, newIndex in
                guard model.items.indices.contains(newIndex) else { return }
                proxy.scrollTo(model.items[newIndex].id, anchor: .center)
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ item: ReviewQueueModel.QueueItem, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(glyph(for: item.state))
                .foregroundStyle(color(for: item.state))
            Text(item.snippet)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(item.isDone)
                .foregroundStyle(index == model.currentIndex ? Color.accentColor : .secondary)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            index == model.currentIndex
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityIdentifier("review.row")
    }

    // MARK: - Main panel

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let paragraph = model.currentParagraph {
                paragraphText(paragraph)
            } else {
                Text("No paragraphs in queue")
                    .foregroundStyle(.secondary)
            }
            notesSection
            transport
            actions
            noteComposer
        }
        .padding(24)
    }

    private var header: some View {
        HStack {
            Text("Review Queue · \(title)")
                .font(.headline)
            Spacer()
            Text("\(model.currentIndex + 1) / \(model.items.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch model.predicate {
        case .flagged: return "Flagged"
        case .needsPickup: return "Needs Pickup"
        case .unapproved: return "Unapproved"
        default: return "Queue"
        }
    }

    private func paragraphText(_ paragraph: Paragraph) -> some View {
        ScrollView {
            Text(paragraph.text)
                .font(.system(size: 22))
                .lineSpacing(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityIdentifier("review.currentParagraph")
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Incoming notes")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.notes.isEmpty {
                Text("No notes for this paragraph")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.notes, id: \.id) { note in
                    Label("\(note.device.rawValue): \(note.text)", systemImage: "note.text")
                        .font(.caption)
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.previousParagraph() }
            } label: {
                Label("Previous ¶", systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button {
                Task { await model.togglePlayback() }
            } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 28))
            }
            .keyboardShortcut(.space, modifiers: [])

            Button {
                Task { await model.nextParagraph() }
            } label: {
                Label("Next ¶", systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Spacer()

            Toggle("Auto-advance", isOn: $model.autoAdvance)
                .toggleStyle(.checkbox)
            Toggle("Play 1 s context", isOn: $model.playContextSecond)
                .toggleStyle(.checkbox)
        }
        .accessibilityIdentifier("review.transport")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Approve & Next") {
                Task { await model.approveAndNext() }
            }
            .keyboardShortcut("a", modifiers: .command)
            .accessibilityIdentifier("review.approve")

            Button("Needs Pickup & Next") {
                Task { await model.needsPickupAndNext() }
            }
            .keyboardShortcut("p", modifiers: .command)
            .accessibilityIdentifier("review.pickup")

            Button("Keep Flagged") {
                Task { await model.keepFlagged() }
            }
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityIdentifier("review.keepFlagged")
        }
    }

    private var noteComposer: some View {
        HStack(spacing: 8) {
            TextField("Add a note (entered on Mac)", text: $model.noteText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("review.noteField")
            Button("Add Note") {
                Task { await model.submitNote() }
            }
            .disabled(model.noteText.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("review.addNote")
        }
    }

    // MARK: - Helpers

    private func moveTo(_ index: Int) async {
        if index > model.currentIndex {
            for _ in model.currentIndex..<index {
                await model.nextParagraph()
            }
        } else {
            for _ in index..<model.currentIndex {
                await model.previousParagraph()
            }
        }
    }

    private func glyph(for state: ReviewState) -> String {
        switch state {
        case .flagged: return "⚑"
        case .needsPickup: return "●"
        case .approved: return "✓"
        case .unreviewed: return "○"
        }
    }

    private func color(for state: ReviewState) -> Color {
        switch state {
        case .flagged: return .orange
        case .needsPickup: return .red
        case .approved: return .green
        case .unreviewed: return .secondary
        }
    }
}
