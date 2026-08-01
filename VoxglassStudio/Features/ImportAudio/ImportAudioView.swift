import SwiftUI
import UniformTypeIdentifiers
import VoxglassCore

/// Spec §18.1.8 / mockup `07-import-audio`: waveform-free import table with
/// origin picker (mandatory), assignment method, segment→paragraph→confidence
/// table, and the LibriVox ineligibility warning.
struct ImportAudioView: View {
    @Bindable var model: ImportAudioModel

    @State private var showFilePicker = false
    @State private var selectedChapterIndex = 0
    @State private var startParagraphIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if !model.segments.isEmpty {
                assignmentControls
                originPicker
                segmentTable
                commitButton
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle("Import Audio")
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio]) { result in
            if case .success(let url) = result {
                Task { await model.loadFile(at: url) }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Import an existing recording and split it across paragraphs.")
                    .foregroundStyle(.secondary)
                if let filename = model.sourceFilename {
                    Text(filename)
                        .font(.callout.monospaced())
                }
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            Spacer()
            Button(model.segments.isEmpty ? "Choose Audio File…" : "Choose Another…") {
                showFilePicker = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var assignmentControls: some View {
        HStack(spacing: 16) {
            Picker("Method", selection: $model.assignmentMethod) {
                ForEach(ImportAudioModel.AssignmentMethod.allCases) { method in
                    Text(label(for: method)).tag(method)
                }
            }
            .accessibilityIdentifier("import.audio.method.\(model.assignmentMethod.rawValue)")
            .onChange(of: model.assignmentMethod) { model.clearAssignments() }

            if model.assignmentMethod == .splitAcrossChapter && !model.allParagraphs.isEmpty {
                Picker("Chapter", selection: $selectedChapterIndex) {
                    ForEach(Array(model.project.chapters.enumerated()), id: \.element.id) { index, chapter in
                        Text(chapter.title).tag(index)
                    }
                }
            } else if !model.allParagraphs.isEmpty {
                Picker("Start at", selection: $startParagraphIndex) {
                    ForEach(Array(model.allParagraphs.enumerated()), id: \.element.id) { index, para in
                        Text("¶ \(index + 1)").tag(index)
                    }
                }
            }
        }
    }

    private var originPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Origin of this recording")
                .font(.headline)
            Picker("Origin", selection: Binding(
                get: { model.origin ?? .importedHuman },
                set: { model.origin = $0 }
            )) {
                ForEach(ImportAudioModel.OriginChoice.allCases) { choice in
                    Text(originLabel(for: choice)).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("import.audio.origin.\(model.origin?.rawValue ?? "importedHuman")")

            if model.origin?.isNonHuman == true {
                if model.origin == .aiImported {
                    TextField("AI provider (required)", text: $model.aiProviderLabel)
                        .textFieldStyle(.roundedBorder)
                }
                Text(model.origin?.warning ?? "")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("import.originWarning")
            }
        }
    }

    private var segmentTable: some View {
        Table(model.segments) {
            TableColumn("Segment") { segment in
                Text(String(format: "%@ – %@",
                            formatTime(segment.start), formatTime(segment.end)))
                    .monospacedDigit()
            }
            TableColumn("Duration") { segment in
                Text(String(format: "%.1f s", segment.duration))
                    .monospacedDigit()
            }
            TableColumn("Paragraph") { segment in
                if let paragraphID = segment.paragraphID {
                    if let index = model.allParagraphs.firstIndex(where: { $0.id == paragraphID }) {
                        Text("¶ \(index + 1)").monospacedDigit()
                    } else {
                        Text("—")
                    }
                } else {
                    Text("unassigned").foregroundStyle(.secondary)
                }
            }
            TableColumn("Confidence") { segment in
                Text(segment.confidence == .high ? "High" : "Review")
            }
        }
        .frame(minHeight: 200)
    }

    private var commitButton: some View {
        HStack {
            Button("Assign \(model.segments.count) Segments") {
                assign()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canAssign)
            .accessibilityIdentifier("import.audio.assign")

            if model.importedTakeCount > 0 {
                Text("Imported \(model.importedTakeCount) take(s).")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func assign() {
        let paragraphIDs: [UUID]
        switch model.assignmentMethod {
        case .sequential:
            let slice = Array(model.allParagraphs[startParagraphIndex...])
            paragraphIDs = Array(slice.prefix(model.segments.count)).map(\.id)
            if paragraphIDs.count < model.segments.count {
                model.error = "Not enough paragraphs remain for \(model.segments.count) segments."
                return
            }
            _ = model.assignSequentially(to: paragraphIDs)
        case .splitAcrossChapter:
            let chapter = model.project.chapters[selectedChapterIndex]
            let ids = chapter.paragraphs.map(\.id)
            guard model.assignSplitAcrossChapter(to: ids) else { return }
        }
        Task { await model.assignAll() }
    }

    private func label(for method: ImportAudioModel.AssignmentMethod) -> String {
        switch method {
        case .sequential: return "Assign detected segments sequentially"
        case .splitAcrossChapter: return "Split file across this chapter"
        }
    }

    private func originLabel(for choice: ImportAudioModel.OriginChoice) -> String {
        switch choice {
        case .importedHuman: return "External human recording"
        case .aiImported: return "AI-generated or AI-processed"
        case .unknownImport: return "Unknown"
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let f = Int((t - t.rounded(.down)) * 10)
        return String(format: "%d:%02d.%d", m, s, f)
    }
}
