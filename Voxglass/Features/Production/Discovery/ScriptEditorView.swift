import SwiftUI
import VoxglassCore

/// The script editor (mockup 05, spec §8.4): a phone-shaped paragraph list with
/// state chips and an inline inspector for editing text, direction, and
/// pronunciation, plus Split here / Merge next. Editing a paragraph that has a
/// selected take raises the drift indicator immediately.
struct ScriptEditorView: View {
    @State private var model: NarrationFlowModel
    @State private var filter: ScriptFilter = .all
    @State private var inspectorParagraphID: UUID?
    @State private var inspectorText = ""
    @State private var showInspector = false

    enum ScriptFilter: String, CaseIterable {
        case all, drift, unrecorded

        var label: String {
            switch self {
            case .all: return "All"
            case .drift: return "Changed"
            case .unrecorded: return "Unrecorded"
            }
        }
    }

    init(project: AudiobookProject) {
        _model = State(initialValue: NarrationFlowModel(existing: project))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar

            let rows = filteredParagraphs
            if rows.isEmpty {
                EmptyStatePanel(
                    title: "Nothing Here",
                    message: "No paragraphs match this filter.",
                    systemImage: "text.alignleft"
                )
                .padding(.top, 40)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            paragraphRow(row)
                            if row.id != rows.last?.id {
                                VoxglassListDivider()
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                }
            }
        }
        .background(VoxglassBackground())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(model.project?.metadata.title ?? "Script")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showInspector) {
            if let inspectorParagraphID {
                ScriptInspectorSheet(
                    model: model,
                    paragraphID: inspectorParagraphID,
                    text: Binding(get: { inspectorText }, set: { inspectorText = $0 })
                )
                .onAppear {
                    inspectorText = model.paragraph(at: inspectorParagraphID)?.text ?? ""
                }
            }
        }
        .accessibilityIdentifier("script.editor")
    }

    @Environment(\.dismiss) private var dismiss

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ScriptFilter.allCases, id: \.self) { item in
                Button {
                    filter = item
                } label: {
                    Text("\(item.label) \(count(for: item))")
                        .scaledFont(size: 11.5, weight: item == filter ? .heavy : .semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(item == filter ? Color(hex: 0x111111) : Palette.ink2)
                        .background(item == filter ? Color(hex: 0xF6F2EA) : Color.white.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(scriptFilterID(for: item))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityIdentifier("script.filter")
    }

    private func scriptFilterID(for item: ScriptFilter) -> String {
        switch item {
        case .all: return "script.filter.all"
        case .drift: return "script.filter.drift"
        case .unrecorded: return "script.filter.unrecorded"
        }
    }

    private func count(for item: ScriptFilter) -> Int {
        switch item {
        case .all: return model.paragraphs.count
        case .drift: return model.paragraphs.count { $0.isDrifted }
        case .unrecorded: return model.paragraphs.count { $0.state == .notRecorded }
        }
    }

    private var filteredParagraphs: [FlowParagraph] {
        switch filter {
        case .all: return model.paragraphs
        case .drift: return model.paragraphs.filter(\.isDrifted)
        case .unrecorded: return model.paragraphs.filter { $0.state == .notRecorded }
        }
    }

    private func paragraphRow(_ paragraph: FlowParagraph) -> some View {
        Button {
            inspectorParagraphID = paragraph.id
            inspectorText = paragraph.text
            showInspector = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("¶ \(number(of: paragraph.id))")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(Palette.ink3)
                    Spacer()
                    stateChip(paragraph)
                }
                Text(paragraph.text)
                    .scaledFont(size: 13.5)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if paragraph.isDrifted, let take = paragraph.take {
                    HStack(spacing: 6) {
                        chip("Take selected · \(take.duration.formattedShort)", tint: Palette.ink3)
                        chip("Recording no longer matches", tint: Color(hex: 0xE6B877))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(borderTint(paragraph).opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .accessibilityIdentifier("script.row.\(number(of: paragraph.id))")
    }

    @ViewBuilder
    private func stateChip(_ paragraph: FlowParagraph) -> some View {
        if paragraph.isDrifted {
            chip("Text changed", tint: Color(hex: 0xE6B877))
        } else {
            switch paragraph.state {
            case .approved: chip("Recorded", tint: Palette.ok)
            case .recorded: chip("Recorded", tint: Palette.ok)
            case .flagged: chip("Needs pickup", tint: Color(hex: 0xE6B877))
            case .notRecorded: chip("Unrecorded", tint: Palette.ink3)
            }
        }
    }

    private func borderTint(_ paragraph: FlowParagraph) -> Color {
        paragraph.isDrifted ? Color(hex: 0xE6B877) : Palette.hairline
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .scaledFont(size: 10, weight: .bold)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }

    private func number(of id: UUID) -> String {
        model.globalNumber(of: id).map { String($0) } ?? "—"
    }
}

// MARK: - Inspector

/// Inline inspector for a paragraph (mockup 05): text, direction note,
/// pronunciation, and Split here / Merge next.
private struct ScriptInspectorSheet: View {
    @Bindable var model: NarrationFlowModel
    let paragraphID: UUID
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @State private var direction = ""
    @State private var pronunciation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("script.inspector.text")
                }

                Section("Direction note") {
                    TextField("Dry, faintly amused", text: $direction)
                        .accessibilityIdentifier("script.inspector.direction")
                }

                Section("Pronunciation") {
                    TextField("Ackroyd — ACK-royd", text: $pronunciation)
                        .accessibilityIdentifier("script.inspector.pronunciation")
                }

                Section {
                    Button("Split here") {
                        splitHere()
                    }
                    .accessibilityIdentifier("script.inspector.splitHere")

                    Button("Merge next") {
                        mergeNext()
                    }
                    .accessibilityIdentifier("script.inspector.mergeNext")
                } footer: {
                    Text("Splitting keeps the existing recording on the first half and marks the second half unrecorded. Nothing is deleted.")
                }
            }
            .navigationTitle("¶ \(model.globalNumber(of: paragraphID) ?? 0)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await model.editParagraphText(paragraphID, to: text) }
                        dismiss()
                    }
                    .accessibilityIdentifier("script.inspector.save")
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("script.inspector")
        .onAppear {
            guard let paragraph = model.project?.allParagraphs.first(where: { $0.id == paragraphID }) else { return }
            direction = paragraph.directionNote ?? ""
            pronunciation = paragraph.pronunciationRefs.isEmpty ? "" : "Set"
        }
    }

    private func splitHere() {
        // Split at a comfortable midpoint: the start of the second sentence if
        // the paragraph has one, else the character midpoint.
        let fullText = model.paragraph(at: paragraphID)?.text ?? text
        let midpoint = fullText.count / 2
        var offset = fullText.indices.first(where: { $0.utf16Offset(in: fullText) >= midpoint })?.utf16Offset(in: fullText) ?? midpoint
        if let sentenceStart = sentenceStart(after: midpoint, in: fullText) {
            offset = sentenceStart
        }
        Task { await model.splitParagraph(paragraphID, atCharacterOffset: offset) }
        dismiss()
    }

    private func sentenceStart(after offset: Int, in fullText: String) -> Int? {
        guard offset < fullText.count else { return nil }
        let tail = fullText.suffix(fullText.count - offset)
        var search = tail.startIndex
        while let dot = tail[search...].firstIndex(of: ".") {
            let candidate = tail.index(after: dot)
            search = candidate
            let rest = tail[candidate...]
            if let firstLetter = rest.firstIndex(where: { $0.isLetter }),
               firstLetter != rest.startIndex {
                return offset + tail.distance(from: tail.startIndex, to: firstLetter)
            }
        }
        return nil
    }

    private func mergeNext() {
        Task { await model.mergeParagraph(paragraphID) }
        dismiss()
    }
}
