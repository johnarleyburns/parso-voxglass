import SwiftUI
import VoxglassCore

// MARK: - p02 Source review

struct SourceReviewView: View {
    @Bindable var model: NarrationFlowModel
    @State private var goRecord = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [Color(hex: 0x101A14), Color(hex: 0x2F5A3E)], startPoint: .top, endPoint: .bottom))
                        Text("📗").scaledFont(size: 22)
                    }
                    .frame(width: 48, height: 62)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.draftTitle.isEmpty ? "Untitled" : model.draftTitle)
                            .scaledFont(size: 17, weight: .heavy)
                            .foregroundStyle(Palette.ink)
                        Text("\(model.draftAuthor.isEmpty ? "Unknown author" : model.draftAuthor) · \(model.sourceURL ?? "")")
                            .scaledFont(size: 12)
                            .foregroundStyle(Palette.ink2)
                    }
                    Spacer()
                    Text("PD · US")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(Palette.brass)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Palette.brass.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Palette.brass.opacity(0.5), lineWidth: 1))
                }
                .padding(13)
                .glassSurface(cornerRadius: 16)

                if let project = model.project {
                    Text("📄 1 piece · \(project.paragraphs.count) spoken paragraphs · ~\(project.duration(of: project.paragraphs).formattedShort)")
                        .scaledFont(size: 12)
                        .foregroundStyle(Palette.ink2)
                        .accessibilityIdentifier("import.chapterCount")

                    Text("WHAT WILL BE RECORDED")
                        .scaledFont(size: 13, weight: .bold)
                        .foregroundStyle(Palette.ink3)
                        .padding(.top, 8)

                    ForEach(Array(project.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        paragraphRow(index: index, paragraph: paragraph)
                    }
                }

                Button {
                    goRecord = true
                } label: {
                    Text("Start recording ▸")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .buttonStyle(.plain)
                .tactileTap()
                .padding(.top, 10)
                .accessibilityIdentifier("import.acceptStructure")
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationDestination(isPresented: $goRecord) {
            if let first = model.project?.paragraphs.first {
                RecordView(model: model, paragraphID: first.id)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paragraphRow(index: Int, paragraph: NarrationParagraph) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(paragraph.role == .body ? Palette.ink3 : Palette.brass)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(paragraph.text)
                    .scaledFont(size: 13.5)
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if paragraph.role != .body {
                    Text(roleLabel(paragraph.role))
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(Palette.brass)
                }
            }
        }
        .padding(11)
        .glassSurface(cornerRadius: 12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(paragraph.role == .body ? Palette.hairline : Palette.brass.opacity(0.4), lineWidth: 1))
    }

    private func roleLabel(_ role: NarrationParagraphRole) -> String {
        switch role {
        case .disclaimer: return "· disclaimer added"
        case .intro: return "· intro added"
        case .outro: return "· outro added"
        case .body: return ""
        }
    }
}

// MARK: - p03 Record

struct RecordView: View {
    @Bindable var model: NarrationFlowModel
    let paragraphID: UUID
    /// True when this view was pushed from the paragraph list (re-record),
    /// so finishing the last paragraph pops back to the list instead of
    /// advancing.
    let fromReview: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var navigateToReview = false

    init(model: NarrationFlowModel, paragraphID: UUID, fromReview: Bool = false) {
        self.model = model
        self.paragraphID = paragraphID
        self.fromReview = fromReview
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let paragraph = model.paragraph(at: currentParagraphID) {
                    teleprompter(paragraph)
                    errorCard
                    recordingBar
                    transport
                    takesRow(paragraph)
                    actions(paragraph)
                } else {
                    Text("Paragraph not found").foregroundStyle(Palette.ink2)
                }
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .onDisappear {
            if model.isRecording {
                Task { await model.stopRecordingParagraph(currentParagraphID) }
            }
        }
        .navigationDestination(isPresented: $navigateToReview) {
            ReviewView(model: model)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The paragraph currently shown: advances in place as the user accepts
    /// paragraphs, so each paragraph does not push a new view onto the stack.
    private var currentParagraphID: UUID {
        model.currentParagraphID ?? paragraphID
    }

    private func teleprompter(_ paragraph: NarrationParagraph) -> some View {
        VStack(spacing: 8) {
            Text(roleLabel(paragraph.role).uppercased())
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(Palette.brass)
            Text(paragraph.text)
                .scaledFont(size: 22, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 18)
        .accessibilityIdentifier("record.teleprompter")
    }

    @ViewBuilder
    private var errorCard: some View {
        if let error = model.importError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error)
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.micPermissionDenied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .buttonStyle(.plain)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.danger.opacity(0.35), lineWidth: 1))
        }
    }

    private var recordingBar: some View {
        VStack(spacing: 8) {
            if model.isRecording {
                Text("● REC").scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.danger)
            } else if let take = model.paragraph(at: currentParagraphID)?.selectedTake {
                Text("Take \(take.duration.formattedShort) · \(String(format: "%.1f", take.peakDBFS ?? -40)) dBFS")
                    .scaledFont(size: 12).foregroundStyle(Palette.ink2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Palette.hairline)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.isRecording ? Palette.danger : Palette.ok)
                        .frame(width: geo.size.width * levelFraction)
                }
            }
            .frame(height: 8)
            .accessibilityIdentifier("record.inputLevel")
        }
        .padding(.vertical, 10)
    }

    private var levelFraction: CGFloat {
        let db = model.level
        return CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    private var transport: some View {
        HStack(spacing: 20) {
            Button {
                model.play(currentParagraphID)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill").scaledFont(size: 40)
            }
            .foregroundStyle(Palette.ink2)
            .accessibilityIdentifier("record.transport.playInContext")

            Button {
                Task {
                    if model.isRecording {
                        await model.stopRecordingParagraph(currentParagraphID)
                    } else {
                        await model.startRecordingParagraph(currentParagraphID)
                    }
                }
            } label: {
                Image(systemName: model.isRecording ? "stop.fill" : "record.circle")
                    .scaledFont(size: 62)
                    .foregroundStyle(model.isRecording ? Palette.danger : Palette.brass)
            }
            .accessibilityIdentifier("record.transport.record")

            Button {
                model.play(currentParagraphID)
            } label: {
                Image(systemName: "play.circle.fill").scaledFont(size: 40)
            }
            .foregroundStyle(Palette.ink2)
            .disabled(model.paragraph(at: currentParagraphID)?.selectedTake == nil)
            .accessibilityIdentifier("record.transport.playTake")
        }
        .padding(.vertical, 10)
    }

    private func takesRow(_ paragraph: NarrationParagraph) -> some View {
        HStack(spacing: 8) {
            if let take = paragraph.selectedTake {
                Text("Take · \(take.duration.formattedShort)")
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(Color(hex: 0x111111))
                    .background(Color(hex: 0xF6F2EA), in: Capsule())
                    .accessibilityIdentifier("record.take.1")
            } else {
                Text("No take yet").scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func actions(_ paragraph: NarrationParagraph) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await goPrevious(from: paragraph) }
            } label: {
                Text("‹ Back")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(Palette.ink)
                    .frame(width: 88, height: 46)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record.previousParagraph")

            Button {
                Task { await goNext(from: paragraph, flag: true) }
            } label: {
                Image(systemName: "flag")
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Color(hex: 0xE6B877))
                    .frame(width: 54, height: 46)
                    .background(Color(hex: 0xE0A44F).opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xE0A44F).opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record.flagAndNext")

            Button {
                Task { await goNext(from: paragraph, flag: false) }
            } label: {
                Text("Accept & Next ▸")
                    .scaledFont(size: 14, weight: .heavy)
                    .foregroundStyle(Color(hex: 0x21170B))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .tactileTap()
            .disabled(paragraph.selectedTake == nil)
            .accessibilityIdentifier("record.acceptAndNext")
        }
        .padding(.top, 8)
    }

    /// Stops any live recording, then either accepts or flags the paragraph
    /// and advances to the next one IN PLACE — no new view on the stack. The
    /// last paragraph finishes into the review list (or pops back to it when
    /// this view was pushed from the list).
    private func goNext(from paragraph: NarrationParagraph, flag: Bool) async {
        if model.isRecording {
            await model.stopRecordingParagraph(paragraph.id)
        }
        if flag {
            model.markNotRecorded(paragraph.id)
            model.updateParagraph(paragraph.id) { $0.state = .flagged }
        } else {
            model.acceptParagraph(paragraph.id)
        }
        if let next = model.nextParagraph(after: paragraph.id) {
            model.currentParagraphID = next.id
        } else if fromReview {
            dismiss()
        } else {
            model.currentParagraphID = nil
            navigateToReview = true
        }
    }

    private func goPrevious(from paragraph: NarrationParagraph) async {
        if model.isRecording {
            await model.stopRecordingParagraph(paragraph.id)
        }
        if let previous = previousParagraph() {
            model.currentParagraphID = previous.id
        }
    }

    private func previousParagraph() -> NarrationParagraph? {
        guard let project = model.project,
              let index = project.paragraphs.firstIndex(where: { $0.id == currentParagraphID }) else { return nil }
        guard index > 0 else { return nil }
        return project.paragraphs[index - 1]
    }

    private func roleLabel(_ role: NarrationParagraphRole) -> String {
        switch role {
        case .disclaimer: return "LibriVox disclaimer"
        case .intro: return "Intro"
        case .outro: return "Outro"
        case .body: return "Paragraph"
        }
    }
}

// MARK: - p04 Review

struct ReviewView: View {
    @Bindable var model: NarrationFlowModel
    @State private var filter: ReviewFilter = .all
    @State private var reRecordID: UUID?

    enum ReviewFilter: String, CaseIterable {
        case all, flagged, pickup
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                Text("All").tag(ReviewFilter.all)
                Text("Flagged").tag(ReviewFilter.flagged)
                Text("Not recorded").tag(ReviewFilter.pickup)
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("paragraphList.filter")

            if let project = model.project {
                let rows = filtered(project.paragraphs)
                List {
                    ForEach(rows) { paragraph in
                        row(paragraph)
                    }
                }
                .listStyle(.plain)

                Button {
                    goAssemble = true
                } label: {
                    Text("Assemble the recording ▸")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                }
                .buttonStyle(.plain)
                .disabled(!project.readyToAssemble)
                .accessibilityIdentifier("review.toAssemble")
            }
        }
        .background(VoxglassBackground())
        .navigationDestination(isPresented: $goAssemble) {
            AssembleView(model: model)
        }
        .navigationDestination(item: $reRecordID) { id in
            RecordView(model: model, paragraphID: id, fromReview: true)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var goAssemble = false

    private func filtered(_ paragraphs: [NarrationParagraph]) -> [NarrationParagraph] {
        switch filter {
        case .all: return paragraphs
        case .flagged: return paragraphs.filter { $0.state == .flagged }
        case .pickup: return paragraphs.filter { $0.state == .notRecorded }
        }
    }

    private func row(_ paragraph: NarrationParagraph) -> some View {
        HStack(spacing: 12) {
            statusIcon(paragraph.state)
            VStack(alignment: .leading, spacing: 3) {
                Text(paragraph.text)
                    .scaledFont(size: 13.5, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(caption(paragraph))
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                if let note = paragraph.note {
                    Text(note).scaledFont(size: 11).foregroundStyle(Color(hex: 0xE6C79C))
                }
            }
            Spacer()
            Button {
                model.play(paragraph.id)
            } label: {
                Image(systemName: "play.circle")
                    .scaledFont(size: 26)
                    .foregroundStyle(Palette.ink2)
            }
            .buttonStyle(.plain)
            .disabled(paragraph.selectedTake == nil)
            .accessibilityIdentifier("paragraphList.playSelected")

            if paragraph.state == .flagged {
                Button("Re-record ▸") {
                    reRecordID = paragraph.id
                }
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(Palette.brass)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private func statusIcon(_ state: NarrationParagraphState) -> some View {
        ZStack {
            Circle().fill(tint(state).opacity(0.16))
            switch state {
            case .approved: Text("✓").scaledFont(size: 13, weight: .heavy).foregroundStyle(tint(state))
            case .flagged: Text("⚑").scaledFont(size: 13).foregroundStyle(tint(state))
            case .recorded: Text("·").scaledFont(size: 13, weight: .heavy).foregroundStyle(tint(state))
            case .notRecorded: Text("○").scaledFont(size: 13).foregroundStyle(Palette.ink3)
            }
        }
        .frame(width: 26, height: 26)
    }

    private func tint(_ state: NarrationParagraphState) -> Color {
        switch state {
        case .approved: return Palette.ok
        case .flagged: return Color(hex: 0xE6B877)
        case .recorded: return Palette.brass
        case .notRecorded: return Palette.ink3
        }
    }

    private func caption(_ paragraph: NarrationParagraph) -> String {
        var parts: [String] = []
        switch paragraph.role {
        case .disclaimer: parts.append("Disclaimer")
        case .intro: parts.append("Intro")
        case .outro: parts.append("Outro")
        case .body: parts.append("¶")
        }
        if let take = paragraph.selectedTake { parts.append(take.duration.formattedShort) }
        parts.append(stateText(paragraph.state))
        return parts.joined(separator: " · ")
    }

    private func stateText(_ state: NarrationParagraphState) -> String {
        switch state {
        case .approved: return "approved"
        case .recorded: return "recorded"
        case .flagged: return "flagged"
        case .notRecorded: return "not recorded"
        }
    }
}

// MARK: - p05 Assemble

struct AssembleView: View {
    @Bindable var model: NarrationFlowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let project = model.project {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(project.title) — full recording")
                            .scaledFont(size: 16, weight: .heavy)
                            .foregroundStyle(Palette.ink)
                        Text("\(project.author) · \(project.paragraphs.count) paragraphs assembled")
                            .scaledFont(size: 12).foregroundStyle(Palette.ink2)
                        Text("Total ~\(project.duration(of: project.paragraphs).formattedShort)")
                            .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.brass)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(cornerRadius: 18)
                    .accessibilityIdentifier("assemble.renderPreview")
                }

                Text("SPACING")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)

                sliderRow("Pause between paragraphs", value: $model.assembly.paragraphGap, range: 0...2, step: 0.05, id: "assemble.paragraphGap")
                sliderRow("Silence at start", value: $model.assembly.chapterHeadSilence, range: 0...2, step: 0.05, id: "assemble.headSilence")
                sliderRow("Silence at end", value: $model.assembly.chapterTailSilence, range: 0...2, step: 0.05, id: "assemble.tailSilence")

                Text("Room-tone padding keeps the file clean for LibriVox and IA. Nothing is re-encoded until you export.")
                    .scaledFont(size: 12).foregroundStyle(Palette.ink3)

                Button {
                    goMetadata = true
                } label: {
                    Text("Add details ▸")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .buttonStyle(.plain)
                .tactileTap()
                .accessibilityIdentifier("assemble.toMetadata")
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationDestination(isPresented: $goMetadata) {
            MetadataView(model: model)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var goMetadata = false

    private func sliderRow(_ label: String, value: Binding<TimeInterval>, range: ClosedRange<Double>, step: Double, id: String) -> some View {
        HStack {
            Text(label).scaledFont(size: 13.5, weight: .semibold).foregroundStyle(Palette.ink)
            Spacer()
            Text(String(format: "%.2f s", value.wrappedValue))
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(Palette.brass)
                .accessibilityIdentifier(id)
        }
        .padding(13)
        .glassSurface(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - p06 Metadata & rights

struct MetadataView: View {
    @Bindable var model: NarrationFlowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                fieldRow("Title", text: titleBinding, id: "metadata.title")
                fieldRow("Author", text: authorBinding, id: "metadata.author")
                fieldRow("Narrator / reader name", text: $model.narrator, id: "metadata.narrator")
                fieldRow("Language", text: $model.language, id: "metadata.language")
                areaRow("Description", text: $model.descriptionText, id: "metadata.description")
                fieldRow("Subjects", text: $model.subjectsText, id: "metadata.subjects")
                fieldRow("Source URL", text: $model.sourceURLText, id: "metadata.sourceURL")

                Text("Chips show where each field is used. LibriVox (LV) · Internet Archive (IA).")
                    .scaledFont(size: 11).foregroundStyle(Palette.ink3)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Rights").scaledFont(size: 14, weight: .bold).foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        Text("LV").scaledFont(size: 9, weight: .heavy).foregroundStyle(Palette.brass)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Palette.brass.opacity(0.14), in: Capsule())
                        Text("IA").scaledFont(size: 9, weight: .heavy).foregroundStyle(Color(hex: 0x8FD0FF))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color(hex: 0x8FD0FF).opacity(0.14), in: Capsule())
                        Text("Public domain in the United States").scaledFont(size: 12).foregroundStyle(Palette.ink2)
                    }
                    Button {
                        model.rightsAttested = true
                        if var project = model.project {
                            project.metadata = NarrationMetadata(
                                narrator: model.narrator,
                                language: model.language,
                                description: model.descriptionText,
                                subjects: model.subjectsText.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) },
                                sourceURL: model.sourceURLText
                            )
                            model.project = project
                        }
                    } label: {
                        Label(model.rightsAttested ? "Rights attested ✓" : "Attest public domain (US)", systemImage: model.rightsAttested ? "checkmark.circle.fill" : "circle")
                            .scaledFont(size: 13.5, weight: .semibold)
                            .foregroundStyle(model.rightsAttested ? Palette.ok : Palette.brass)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("metadata.attest")
                    Text("I attest this information is accurate and this work is in the public domain in the US. \(LegalStrings.noCopyrightDetermination)")
                        .scaledFont(size: 11).foregroundStyle(Palette.ink3)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(cornerRadius: 14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.brass.opacity(0.35), lineWidth: 1))

                Button {
                    goExport = true
                } label: {
                    Text("Validate & export ▸")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .buttonStyle(.plain)
                .disabled(!model.rightsAttested)
                .accessibilityIdentifier("metadata.toExport")
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goExport) {
            ValidateExportView(model: model)
        }
    }

    @State private var goExport = false

    private func fieldRow(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .scaledFont(size: 11, weight: .bold).foregroundStyle(Palette.ink3)
            TextField("", text: text)
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink)
                .padding(11)
                .background(Color(hex: 0x0F1316), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
                .accessibilityIdentifier(id)
        }
    }

    private func areaRow(_ label: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .scaledFont(size: 11, weight: .bold).foregroundStyle(Palette.ink3)
            TextEditor(text: text)
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink)
                .frame(minHeight: 60)
                .padding(6)
                .background(Color(hex: 0x0F1316), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
                .accessibilityIdentifier(id)
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.project?.title ?? "" },
            set: { if var p = model.project { p.title = $0; model.project = p } }
        )
    }

    private var authorBinding: Binding<String> {
        Binding(
            get: { model.project?.author ?? "" },
            set: { if var p = model.project { p.author = $0; model.project = p } }
        )
    }
}

// MARK: - p07 Validate & export

struct ValidateExportView: View {
    @Bindable var model: NarrationFlowModel
    @State private var librivoxEnabled = true
    @State private var archiveEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("CHECKS")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)
                checkRow(title: "Title, author, narrator, language", ok: hasMetadata, note: hasMetadata ? "present" : "missing", id: "validate.report")
                checkRow(title: "Rights attested · public domain (US)", ok: model.rightsAttested, note: model.rightsAttested ? "ok" : "required")
                checkRow(title: "LibriVox disclaimer recorded", ok: hasDisclaimer, note: hasDisclaimer ? "intro + outro" : "missing")
                checkRow(title: "Human narration (no AI audio)", ok: true, note: "eligible")
                checkRow(title: "No clipping", ok: !clippingDetected, note: clippingDetected ? "check takes" : "ok")
                checkRow(title: "Level", ok: true, note: "acceptable")

                Text("PUBLISH TO")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)
                    .padding(.top, 6)

                destinationCard(
                    icon: "📻", title: "LibriVox",
                    formats: ["MP3", "128 kbps CBR", "mono", "44.1 kHz", "ID3 tags"],
                    enabled: $librivoxEnabled,
                    id: "export.destination.librivox",
                    filename: model.exportBundle?.filename
                )
                destinationCard(
                    icon: "🏛️", title: "Internet Archive",
                    formats: ["FLAC master", "+ MP3 derivative", "metadata.json", "checksums"],
                    enabled: $archiveEnabled,
                    id: "export.destination.internetArchive"
                )

                Text("FLAC/MP3 encoding isn't available on iPhone yet — record and export on your Mac to produce encoded audio. Your paragraph takes transfer with the project.")
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)

                Button {
                    model.buildExport()
                    goSubmit = true
                } label: {
                    Text("Produce files ▸")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .buttonStyle(.plain)
                .disabled(!hasMetadata)
                .accessibilityIdentifier("export.run")
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationDestination(isPresented: $goSubmit) {
            SubmitView(model: model)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var goSubmit = false

    private var hasMetadata: Bool {
        guard let project = model.project else { return false }
        return !project.title.isEmpty
            && !project.author.isEmpty
            && !model.narrator.isEmpty
            && !model.language.isEmpty
    }

    private var hasDisclaimer: Bool {
        guard let project = model.project else { return false }
        return project.paragraphs.contains { $0.role == .disclaimer && $0.state == .approved }
            && project.paragraphs.contains { $0.role == .outro && $0.state == .approved }
    }

    private var clippingDetected: Bool {
        guard let project = model.project else { return false }
        return project.paragraphs.contains { $0.selectedTake?.clipped == true }
    }

    private func checkRow(title: String, ok: Bool, note: String, id: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .scaledFont(size: 13, weight: .heavy)
                .foregroundStyle(ok ? Palette.ok : Color(hex: 0xE6B877))
                .frame(width: 22)
            Text(title).scaledFont(size: 13).foregroundStyle(Palette.ink)
            Spacer()
            Text(note).scaledFont(size: 11).foregroundStyle(Palette.ink3)
        }
        .padding(8)
        .accessibilityIdentifier(id ?? "validate.report")
    }

    private func destinationCard(icon: String, title: String, formats: [String], enabled: Binding<Bool>, id: String, filename: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(icon).scaledFont(size: 18)
                Text(title).scaledFont(size: 15, weight: .heavy).foregroundStyle(Palette.ink)
                Spacer()
                Toggle("", isOn: enabled).labelsHidden().tint(Palette.brass)
            }
            HStack(spacing: 8) {
                ForEach(formats, id: \.self) { format in
                    Text(format)
                        .scaledFont(size: 11, weight: .bold)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(Color(hex: 0xCFD6E0))
                        .background(Color(hex: 0x0F1316), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hairline, lineWidth: 1))
                }
            }
            if let filename {
                Text(filename)
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                    .monospaced()
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x0F1316), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("export.filename")
            }
            Text("Encoder unavailable on this device — finish on your Mac.")
                .scaledFont(size: 11).foregroundStyle(Color(hex: 0xE6B877))
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.brass.opacity(0.45), lineWidth: 1))
        .accessibilityIdentifier(id)
    }
}

// MARK: - p08 Submit & hand off

struct SubmitView: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 6) {
                    Text("🎉").scaledFont(size: 40)
                    Text("Your recording is ready")
                        .scaledFont(size: 22, weight: .heavy).foregroundStyle(Palette.ink)
                    if let project = model.project {
                        Text("\"\(project.title)\" by \(project.author) · a publishable public-domain recording")
                            .scaledFont(size: 12).foregroundStyle(Palette.ink2)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("export.packageReady")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

                if let bundle = model.exportBundle {
                    VStack(spacing: 0) {
                        ForEach(Array(bundle.files.enumerated()), id: \.offset) { _, url in
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color.white.opacity(0.06))
                                    Text(url.pathExtension.uppercased())
                                        .scaledFont(size: 10, weight: .bold).foregroundStyle(Palette.ink3)
                                }
                                .frame(width: 30, height: 30)
                                Text(url.lastPathComponent).scaledFont(size: 12.5).foregroundStyle(Palette.ink).lineLimit(1)
                                Spacer()
                                Text(byteString(url)).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                            }
                            .padding(.vertical, 9)
                            VoxglassListDivider()
                        }
                    }
                    .padding(.horizontal, 13)
                    .glassSurface(cornerRadius: 14)
                }

                ShareLink(item: shareItem) {
                    Label("Share / Save to Files", systemImage: "square.and.arrow.up")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .accessibilityIdentifier("export.share")

                Text("SUBMIT TO LIBRIVOX")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3).padding(.top, 6)
                submitStep(1, "Open this week's Weekly Poetry thread and claim the poem.")
                submitStep(2, "Upload the MP3 to the LibriVox uploader (from your Mac).")
                submitStep(3, "Post the link in the thread with your reader name. The checklist has the exact steps.")

                Link(destination: URL(string: "https://forum.librivox.org/viewforum.php?f=28")!) {
                    Label("Open the Weekly Poetry thread →", systemImage: "safari")
                        .scaledFont(size: 14, weight: .bold)
                        .foregroundStyle(Palette.brass)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Palette.brass.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.brass.opacity(0.45), lineWidth: 1))
                }
                .accessibilityIdentifier("export.submitToLibriVox")

                Text("OR INTERNET ARCHIVE")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3).padding(.top, 6)
                Button {
                    UIPasteboard.general.string = archiveCommand
                } label: {
                    Label("Prepare Archive upload (opensource_audio) →", systemImage: "doc.on.clipboard")
                        .scaledFont(size: 14, weight: .bold)
                        .foregroundStyle(Color(hex: 0x9FC3FF))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: 0x7896DC).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0x7896DC).opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("export.uploadToArchive")

                Text("Voxglass prepares files; **you submit them yourself**. Voxglass never uploads on your behalf and does not determine copyright status.")
                    .scaledFont(size: 11)
                    .foregroundStyle(Palette.ink3)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shareItem: URL {
        model.exportBundle?.directory
            ?? FileManager.default.temporaryDirectory
    }

    private var archiveCommand: String {
        guard let bundle = model.exportBundle else { return "" }
        let identifier = (model.project?.title ?? "voxglass").lowercased().replacingOccurrences(of: " ", with: "-")
        return "ia upload \(identifier) --metadata='mediatype:audio' --metadata='collection:opensource_audio' --metadata='title:\(model.project?.title ?? "")' --metadata='creator:\(model.project?.author ?? "")' \(bundle.files.map(\.lastPathComponent).joined(separator: " "))"
    }

    private func submitStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .scaledFont(size: 12, weight: .heavy)
                .foregroundStyle(Palette.brass)
                .frame(width: 22, height: 22)
                .background(Palette.brass.opacity(0.16), in: Circle())
                .overlay(Circle().stroke(Palette.brass.opacity(0.4), lineWidth: 1))
            Text(LocalizedStringKey(text)).scaledFont(size: 13).foregroundStyle(Palette.ink)
        }
    }

    private func byteString(_ url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
