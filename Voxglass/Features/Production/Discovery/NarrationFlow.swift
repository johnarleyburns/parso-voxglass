import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import VoxglassCore

// MARK: - Flow model

enum NarrationStep: Hashable {
    case importWork
    case reviewSource
    case record(paragraphID: UUID)
    case reviewList
    case assemble
    case metadata
    case validateExport
    case submit
}

/// The eight-step short-work production flow (NARRATION_NEEDS_SPEC §11.4,
/// p01–p08). Single-work and short-only on iPhone. A project may be left and
/// resumed at any step.
@MainActor
@Observable
final class NarrationFlowModel {
    enum ImportSource {
        case need(NarrationNeed)
        case paste
        case files
        case gutenberg
    }

    var project: NarrationProject?
    var draftTitle = ""
    var draftAuthor = ""
    var draftText = ""
    var sourceURL: String?
    var importError: String?
    var isImporting = false

    var currentParagraphID: UUID?
    var capture = AudioSessionCapture()
    var isRecording = false
    var level: Float = 0
    var currentTake: NarrationTake?
    var playbackPlayer: AVAudioPlayer?

    var assembly = AssemblySettings()
    var metadata = NarrationMetadata(narrator: "", language: "English", description: "", subjects: [], sourceURL: "")
    var narrator = ""
    var language = "English"
    var descriptionText = ""
    var subjectsText = ""
    var sourceURLText = ""
    var rightsAttested = false
    var exportBundle: NarrationExportBundle?

    let store: NarrationProjectStore
    let fetcher: any HTTPFetching

    init(store: NarrationProjectStore = NarrationProjectStore(), fetcher: any HTTPFetching = URLSessionFetcher(), existing: NarrationProject? = nil) {
        self.store = store
        self.fetcher = fetcher
        self.project = existing
        if let existing {
            draftTitle = existing.title
            draftAuthor = existing.author
        }
    }

    // MARK: - Import

    func importNeed(_ need: NarrationNeed) {
        draftTitle = need.work.title
        draftAuthor = need.work.author
        draftText = need.work.text ?? ""
        sourceURL = need.work.sourcePageURL?.absoluteString
    }

    func importPastedText(title: String, author: String, text: String) {
        draftTitle = title
        draftAuthor = author
        draftText = text
        sourceURL = nil
    }

    func fetchGutenberg(identifier: String) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            importError = "Enter a gutenberg.org link or ebook number."
            return
        }
        let ebookID = id.contains("gutenberg.org") ? (URL(string: id)?.lastPathComponent ?? id) : id
        guard let url = URL(string: "https://www.gutenberg.org/cache/epub/\(ebookID)/pg\(ebookID).txt") else {
            importError = "Couldn't build a Gutenberg URL."
            return
        }
        do {
            let result = try await fetcher.get(url, timeout: 15, userAgent: "Voxglass/1.1 (narration-needs; contact: hello@parso.guru)")
            guard result.statusCode == 200 else {
                importError = "Gutenberg returned HTTP \(result.statusCode)."
                return
            }
            let text = String(decoding: result.data, as: UTF8.self)
            draftText = stripProjectGutenberg(text)
            sourceURL = "https://www.gutenberg.org/ebooks/\(ebookID)"
            // Best-effort title/author from the header block.
            if let titleLine = firstHeaderLine(text, matching: "Title:") { draftTitle = titleLine }
            if let authorLine = firstHeaderLine(text, matching: "Author:") { draftAuthor = authorLine }
        } catch {
            importError = "Couldn't reach Project Gutenberg. Paste the text instead."
        }
    }

    // MARK: - Segmentation

    /// Builds the paragraph list: auto-inserted LibriVox disclaimer intro/outro
    /// plus the segmented body (p02).
    func buildParagraphs() {
        let body = draftText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var paragraphs: [NarrationParagraph] = []
        paragraphs.append(NarrationParagraph(
            text: "This is a LibriVox recording. All LibriVox recordings are in the public domain. For more information, or to volunteer, please visit librivox dot org.",
            role: .disclaimer
        ))
        let title = draftTitle.isEmpty ? "This work" : draftTitle
        paragraphs.append(NarrationParagraph(
            text: "\(title), by \(draftAuthor.isEmpty ? "Unknown" : draftAuthor). Read for LibriVox by \(metadata.narrator.isEmpty ? "your name" : metadata.narrator).",
            role: .intro
        ))
        for text in body {
            paragraphs.append(NarrationParagraph(text: text, role: .body))
        }
        paragraphs.append(NarrationParagraph(
            text: "End of \(title). This recording is in the public domain.",
            role: .outro
        ))

        let project = NarrationProject(
            title: title,
            author: draftAuthor,
            sourceText: draftText,
            sourceURL: sourceURL,
            paragraphs: paragraphs
        )
        self.project = project
        store.save(project)
    }

    func paragraph(at id: UUID) -> NarrationParagraph? {
        project?.paragraphs.first { $0.id == id }
    }

    func nextParagraph(after id: UUID) -> NarrationParagraph? {
        guard let project else { return nil }
        guard let index = project.paragraphs.firstIndex(where: { $0.id == id }) else { return nil }
        let nextIndex = project.paragraphs.index(after: index)
        guard project.paragraphs.indices.contains(nextIndex) else { return nil }
        return project.paragraphs[nextIndex]
    }

    func updateParagraph(_ id: UUID, _ transform: (inout NarrationParagraph) -> Void) {
        guard var project else { return }
        guard let index = project.paragraphs.firstIndex(where: { $0.id == id }) else { return }
        transform(&project.paragraphs[index])
        self.project = project
        store.save(project)
    }

    // MARK: - Recording

    func startRecordingParagraph(_ id: UUID) async {
        guard let project, let paragraph = paragraph(at: id) else { return }
        let dir = store.takesDirectory(for: project.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(paragraph.id.uuidString).caf")
        do {
            try await capture.prepare(device: nil, format: RecordingDefaults(sampleRate: 44_100, bitDepth: 24))
            try await capture.startRecording(to: url)
            isRecording = true
            monitorLevels()
        } catch {
            importError = "Microphone unavailable."
        }
    }

    func stopRecordingParagraph(_ id: UUID) async {
        do {
            let take = try await capture.stopRecording()
            isRecording = false
            let fileName = "\(id.uuidString).caf"
            let recorded = NarrationTake(fileName: fileName, duration: take.duration, peakDBFS: take.peakDBFS, clipped: take.clippedDuringCapture)
            updateParagraph(id) { paragraph in
                paragraph.selectedTake = recorded
                paragraph.state = .recorded
            }
            currentTake = recorded
        } catch {
            isRecording = false
        }
    }

    func acceptParagraph(_ id: UUID) {
        updateParagraph(id) { paragraph in
            paragraph.state = .approved
            if paragraph.selectedTake == nil {
                paragraph.selectedTake = currentTake
            }
        }
        currentTake = nil
    }

    func flagParagraph(_ id: UUID, note: String) {
        updateParagraph(id) { paragraph in
            paragraph.state = .flagged
            paragraph.note = note.isEmpty ? paragraph.note : note
        }
        currentTake = nil
    }

    func markNotRecorded(_ id: UUID) {
        updateParagraph(id) { paragraph in
            paragraph.state = .notRecorded
        }
    }

    // MARK: - Levels

    private func monitorLevels() {
        Task { [weak self] in
            guard let self else { return }
            for await levels in self.capture.levels {
                self.level = max(levels.peakDBFS, -60)
            }
        }
    }

    func playbackURL(for id: UUID) -> URL? {
        guard let project, let paragraph = paragraph(at: id), let take = paragraph.selectedTake else { return nil }
        return store.takeURL(projectID: project.id, fileName: take.fileName)
    }

    func play(_ id: UUID) {
        guard let url = playbackURL(for: id) else { return }
        playbackPlayer = try? AVAudioPlayer(contentsOf: url)
        playbackPlayer?.play()
    }

    // MARK: - Export

    func buildExport() {
        guard var project, project.rightsAttested else { return }
        // A LibriVox/IA package requires encoded audio, which iOS cannot
        // produce yet (no LAME/FLAC iOS slices — §11.4 / D-6). We prepare the
        // textual package + filenames; the encoded destinations are flagged
        // "Encoder unavailable" and the user finishes on the Mac.
        let sanitizer = FilenameSanitizer()
        let filename = sanitizer.librivoxFilename(
            shortTitle: project.title,
            section: 1,
            sectionCount: 1,
            authorLastName: Self.lastWord(project.author)
        ) + ".mp3"
        let exportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Voxglass/Exports/\(project.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let checklist = Self.checklist(project: project, filename: filename)
        let checklistURL = exportDir.appendingPathComponent("librivox-checklist.md")
        try? checklist.write(to: checklistURL, atomically: true, encoding: .utf8)

        let manifest = Self.manifestJSON(project: project, filename: filename)
        let manifestURL = exportDir.appendingPathComponent("metadata.json")
        try? manifest.write(to: manifestURL, options: .atomic)

        let durations = Self.sectionDurations(project: project, filename: filename)
        let durationsURL = exportDir.appendingPathComponent("section-durations.txt")
        try? durations.write(to: durationsURL, atomically: true, encoding: .utf8)

        exportBundle = NarrationExportBundle(
            directory: exportDir,
            filename: filename,
            files: [checklistURL, manifestURL, durationsURL],
            totalDuration: project.duration(of: project.paragraphs)
        )
    }

    private static func checklist(project: NarrationProject, filename: String) -> String {
        let approved = project.paragraphs.filter { $0.state == .approved }
        var lines: [String] = []
        lines.append("# LibriVox submission checklist — \(project.title) by \(project.author)")
        lines.append("")
        lines.append("**\(LegalStrings.userSubmits)**")
        lines.append("")
        lines.append("## Technical")
        lines.append("- [ ] MP3 \(Int(DestinationProfile.librivox.audio.bitrateKbps ?? 128)) kbps CBR, mono, 44.1 kHz — encode on your Mac with Voxglass Studio")
        lines.append("- [ ] File: \(filename)")
        lines.append("")
        lines.append("## Content")
        lines.append("- [x] LibriVox disclaimer recorded (intro + outro)")
        lines.append("- [x] \(approved.count) of \(project.paragraphs.count) paragraphs approved on this iPhone")
        lines.append("- [ ] Final recording assembled on the Mac")
        lines.append("")
        lines.append("## Rights")
        lines.append("- Source: \(project.sourceURL ?? "—")")
        lines.append("- Basis: Public domain (US) — \(project.rightsAttested ? "attested in-app" : "not attested")")
        lines.append("")
        lines.append(LegalStrings.noCopyrightDetermination)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func manifestJSON(project: NarrationProject, filename: String) -> Data {
        let dict: [String: Any] = [
            "generator": "Voxglass iOS 1.1 (narration-needs)",
            "destination": "librivox",
            "project": ["title": project.title, "author": project.author, "narrator": project.metadata?.narrator ?? ""],
            "audio": ["codec": "mp3", "bitrateKbps": 128, "cbr": true, "sampleRate": 44100, "channels": 1],
            "files": [["name": filename, "role": "chapter"]],
            "disclaimers": ["intro": "present", "outro": "present"]
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func sectionDurations(project: NarrationProject, filename: String) -> String {
        var lines = project.paragraphs.enumerated().map { index, paragraph in
            let duration = paragraph.selectedTake?.duration ?? 0
            return "\(filename)\t\(clockTime(duration))"
        }
        lines.append("TOTAL\t\t\(clockTime(project.duration(of: project.paragraphs)))")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clockTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func lastWord(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .last
            .map(String.init) ?? ""
    }

    private func stripProjectGutenberg(_ text: String) -> String {
        var t = text
        if let range = t.range(of: "*** START OF THE PROJECT GUTENBERG EBOOK") {
            t = String(t[range.upperBound...])
        }
        if let range = t.range(of: "*** END OF THE PROJECT GUTENBERG EBOOK") {
            t = String(t[..<range.lowerBound])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstHeaderLine(_ text: String, matching key: String) -> String? {
        for line in text.split(separator: "\n").prefix(40) {
            if line.hasPrefix(key) {
                return line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

struct NarrationExportBundle: Equatable {
    var directory: URL
    var filename: String
    var files: [URL]
    var totalDuration: TimeInterval
}

// MARK: - Root

/// Presents the eight-step flow; a fresh project starts at Import (p01), an
/// existing one resumes at Record.
struct NarrationFlowRoot: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @Environment(\.dismiss) private var dismiss
    @State private var model: NarrationFlowModel
    let existing: NarrationProject?
    let startNeed: NarrationNeed?

    init(existing: NarrationProject? = nil, startNeed: NarrationNeed? = nil) {
        self.existing = existing
        self.startNeed = startNeed
        _model = State(initialValue: NarrationFlowModel(existing: existing))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.project != nil {
                    FlowResumeRouter(model: model)
                } else {
                    WorkImportView(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            if let startNeed {
                model.importNeed(startNeed)
                model.buildParagraphs()
            }
        }
        .onChange(of: model.project) { _, newProject in
            if let newProject { discovery.save(newProject) }
        }
    }
}

private struct FlowResumeRouter: View {
    @Bindable var model: NarrationFlowModel

    var body: some View {
        if let project = model.project {
            if let firstUnrecorded = project.paragraphs.first(where: { $0.state == .notRecorded || $0.state == .flagged }) {
                RecordView(model: model, paragraphID: firstUnrecorded.id)
            } else if !project.readyToAssemble {
                ReviewView(model: model)
            } else if !model.rightsAttested {
                AssembleView(model: model)
            } else {
                SubmitView(model: model)
            }
        }
    }
}

// MARK: - p01 Import

struct WorkImportView: View {
    @Bindable var model: NarrationFlowModel
    @Environment(DiscoveryEnvironment.self) private var discovery
    @State private var showNeedsPicker = false
    @State private var showPaste = false
    @State private var showGutenberg = false
    @State private var pickedFileURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Narration")
                    .scaledFont(size: 26, weight: .heavy)
                    .foregroundStyle(Palette.ink)
                Text("Record a public-domain short work — a poem, a short story, an essay.")
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.ink2)

                importOption(icon: "🎙️", title: "From a Narration Need", tag: "Recommended", caption: "This week's poem, or a work that needs a reader", id: "import.fromNeed") {
                    showNeedsPicker = true
                }
                importOption(icon: "📝", title: "Paste text", caption: "Paste a poem or short piece", id: "import.paste") {
                    showPaste = true
                }
                importOption(icon: "📄", title: "Import EPUB from Files", caption: "An .epub on your iPhone or iCloud Drive", id: "import.files") {
                    presentFilesPicker()
                }
                importOption(icon: "🌐", title: "Fetch from Project Gutenberg", caption: "Paste a gutenberg.org link or ebook number", id: "import.gutenberg") {
                    showGutenberg = true
                }

                if model.isImporting {
                    HStack(spacing: 8) {
                        ProgressView().tint(Palette.brass)
                        Text("Fetching…").scaledFont(size: 12).foregroundStyle(Palette.ink2)
                    }
                    .padding(.top, 8)
                }
                if let error = model.importError {
                    Text(error).scaledFont(size: 12).foregroundStyle(Palette.danger)
                }

                Text(LegalStrings.noCopyrightDetermination)
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .sheet(isPresented: $showNeedsPicker) {
            NeedPickerSheet(model: model)
        }
        .sheet(isPresented: $showPaste) {
            PasteSheet(model: model)
        }
        .sheet(isPresented: $showGutenberg) {
            GutenbergSheet(model: model)
        }
        .fileImporter(isPresented: Binding(get: { pickedFileURL != nil }, set: { if !$0 { pickedFileURL = nil } }), allowedContentTypes: [.epub]) { result in
            if case .success(let url) = result {
                importEpub(url)
            }
        }
    }

    private func importOption(icon: String, title: String, tag: String? = nil, caption: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Color(hex: 0x2A2417), Color(hex: 0x5A4A2B)], startPoint: .top, endPoint: .bottom))
                    Text(icon).scaledFont(size: 20)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).scaledFont(size: 15, weight: .bold).foregroundStyle(Palette.ink)
                        if let tag {
                            Text(tag).scaledFont(size: 10, weight: .bold).foregroundStyle(Palette.brass)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Palette.brass.opacity(0.12), in: Capsule())
                                .overlay(Capsule().stroke(Palette.brass.opacity(0.5), lineWidth: 1))
                        }
                    }
                    Text(caption).scaledFont(size: 12).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(size: 12).foregroundStyle(Palette.ink3)
            }
            .padding(14)
            .glassSurface(cornerRadius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .tactileTap()
        .accessibilityIdentifier(id)
    }

    private func presentFilesPicker() {
        pickedFileURL = URL(fileURLWithPath: "/") // triggers the sheet
    }

    private func importEpub(_ url: URL) {
        Task {
            model.isImporting = true
            defer { model.isImporting = false }
            do {
                let doc = try await EPUBImporter().extract(from: url)
                model.draftTitle = doc.title ?? ""
                model.draftAuthor = doc.author ?? ""
                model.draftText = doc.plainText
                model.sourceURL = url.lastPathComponent
            } catch {
                model.importError = "Couldn't read that EPUB."
            }
        }
    }
}

private struct NeedPickerSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(DiscoveryEnvironment.self) private var discovery
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            let needs = discovery.needs.filter { $0.narratableOn.contains(.iOS) && ($0.work.text?.isEmpty == false) }
            List {
                if needs.isEmpty {
                    Text("No ready-to-record needs with embedded text right now — try Paste text.")
                }
                ForEach(needs.prefix(20)) { need in
                    Button {
                        model.importNeed(need)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(need.work.title).font(.headline)
                            Text("\(need.work.author) · \(shortDuration(need.work.estSeconds))").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("From a Need")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PasteSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title).accessibilityIdentifier("metadata.title")
                TextField("Author", text: $author).accessibilityIdentifier("metadata.author")
                TextEditor(text: $text).frame(minHeight: 200)
            }
            .navigationTitle("Paste text")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use this text") {
                        model.importPastedText(title: title, author: author, text: text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct GutenbergSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ebook number or gutenberg.org link", text: $identifier)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("import.gutenberg")
                } footer: {
                    Text("Fetch is best-effort and offline-friendly: if it fails, Paste text instead.")
                }
            }
            .navigationTitle("Project Gutenberg")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fetch") {
                        let id = identifier
                        dismiss()
                        Task { await model.fetchGutenberg(identifier: id) }
                    }
                    .disabled(identifier.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
