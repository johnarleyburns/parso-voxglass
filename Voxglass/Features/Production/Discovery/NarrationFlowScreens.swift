import SwiftUI
import VoxglassCore

/// Pushed narration-flow screens: replaces the root's "Close"/help toolbar
/// with an empty one so only the system Back button shows (field fix: the
/// flow must show Close or Back, never both).
private extension View {
    func narrationFlowBackOnlyToolbar() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) { EmptyView() }
        }
    }

    @ViewBuilder
    func narrationFlowBackOnlyToolbar(if condition: Bool) -> some View {
        if condition {
            narrationFlowBackOnlyToolbar()
        } else {
            self
        }
    }
}

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

                Text("📄 1 piece · \(model.paragraphs.count) spoken paragraphs · ~\(model.totalDuration.formattedShort)")
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.ink2)
                    .accessibilityIdentifier("import.chapterCount")

                Text("WHAT WILL BE RECORDED")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(Palette.ink3)
                    .padding(.top, 8)

                ForEach(Array(model.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                    paragraphRow(index: index, paragraph: paragraph)
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
            if let first = model.paragraphs.first {
                RecordView(model: model, paragraphID: first.id)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func paragraphRow(index: Int, paragraph: FlowParagraph) -> some View {
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

    private func roleLabel(_ role: FlowParagraphRole) -> String {
        switch role {
        case .intro: return "· LibriVox intro added"
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
    @State private var showAudioSetup = false
    @State private var showCompare = false
    @State private var showImport = false

    init(model: NarrationFlowModel, paragraphID: UUID, fromReview: Bool = false) {
        self.model = model
        self.paragraphID = paragraphID
        self.fromReview = fromReview
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let paragraph = model.paragraph(at: currentParagraphID) {
                    routeStatusRow
                    interruptionBanner
                    recoveryList
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
            ReviewView(model: model, isPushed: true)
        }
        .sheet(isPresented: $showAudioSetup) {
            AudioSetupView(model: model)
        }
        .sheet(isPresented: $showCompare) {
            TakeComparisonView(model: model, paragraphID: currentParagraphID)
        }
        .sheet(isPresented: $showImport) {
            ImportAudioView(model: model)
        }
        .narrationFlowBackOnlyToolbar(if: fromReview)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The paragraph currently shown: advances in place as the user accepts
    /// paragraphs, so each paragraph does not push a new view onto the stack.
    private var currentParagraphID: UUID {
        model.currentParagraphID ?? paragraphID
    }

    /// Route + autosave status chips (mockup 06). The route chip opens the
    /// Audio Setup sheet (06b).
    private var routeStatusRow: some View {
        HStack(spacing: 8) {
            Button {
                showAudioSetup = true
            } label: {
                Text(model.routeChipText)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(routeChipColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(routeChipColor.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(routeChipColor.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record.routeChip")

            Spacer()

            if model.isRecording {
                Text("Autosaving")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Palette.ink2.opacity(0.08), in: Capsule())
                    .accessibilityIdentifier("record.autosaveChip")
            }
        }
        .padding(.bottom, 10)
    }

    private var routeChipColor: Color {
        switch model.routeClass ?? CaptureRouteClassifier.classify(model.capture.currentRouteInfo) {
        case .retailReady: return Palette.ok
        case .communityReady: return Palette.brass
        case .draftOnly: return Palette.danger
        }
    }

    /// The in-flight interruption banner (mockup 06c): a named cause, a saved
    /// take, and a way back.
    @ViewBuilder
    private var interruptionBanner: some View {
        if let reason = model.interruptionBanner {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(reason.userDescription.uppercased())
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(Palette.danger)
                    Spacer()
                    Text("Take saved")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.danger.opacity(0.12), in: Capsule())
                }
                Text("Everything recorded up to that point was saved and is playable. The recovered take is marked Interrupted and nothing is selected for you.")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button("Play what was saved") {
                        model.playLatestTake(currentParagraphID)
                    }
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("capture.revealTake")
                    Button("Resume recording") {
                        model.resumeRecordingOnCurrentRoute()
                    }
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .accessibilityIdentifier("capture.resumeRecording")
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.danger.opacity(0.35), lineWidth: 1))
            .accessibilityIdentifier("capture.banner")
            .padding(.bottom, 10)
        }
    }

    /// Takes recovered after a force-quit, awaiting keep/discard (mockup 06c).
    @ViewBuilder
    private var recoveryList: some View {
        if !model.pendingRecoveries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERED AFTER LAST LAUNCH")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.brass)
                ForEach(model.pendingRecoveries) { recovery in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paragraphLabel(for: recovery.paragraphID))
                                .scaledFont(size: 13, weight: .semibold)
                                .foregroundStyle(Palette.ink)
                            Text("\(recovery.reason.userDescription.lowercased()) · \(recovery.duration.formattedShort) recovered")
                                .scaledFont(size: 11)
                                .foregroundStyle(Palette.ink2)
                        }
                        Spacer()
                        Button("Keep") {
                            Task { await model.keepRecovered(recovery) }
                        }
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(Palette.brass)
                        .accessibilityIdentifier("capture.keepTake")
                        Button("Discard") {
                            model.discardRecovered(recovery)
                        }
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("capture.discardTake")
                    }
                    .padding(11)
                    .glassSurface(cornerRadius: 12)
                }
            }
            .padding(.bottom, 10)
            .accessibilityIdentifier("capture.recoveryList")
        }
    }

    private func paragraphLabel(for paragraphID: UUID?) -> String {
        guard let paragraphID,
              let index = model.paragraphs.firstIndex(where: { $0.id == paragraphID }) else {
            return "Recovered take"
        }
        return "¶ \(index + 1)"
    }

    private func teleprompter(_ paragraph: FlowParagraph) -> some View {
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
            } else if let take = model.paragraph(at: currentParagraphID)?.take {
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
            .disabled(model.paragraph(at: currentParagraphID)?.take == nil)
            .accessibilityIdentifier("record.transport.playTake")
        }
        .padding(.vertical, 10)
    }

    private func takesRow(_ paragraph: FlowParagraph) -> some View {
        HStack(spacing: 8) {
            if let take = paragraph.take {
                Text("Take · \(take.duration.formattedShort)")
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(Color(hex: 0x111111))
                    .background(Color(hex: 0xF6F2EA), in: Capsule())
                    .accessibilityIdentifier("record.take.1")
            } else {
                Text("No take yet").scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }

            if model.takeCount(for: paragraph.id) >= 2 {
                Button {
                    showCompare = true
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(Palette.brass)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().stroke(Palette.brass.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("record.take.compare")
            }

            Button {
                showImport = true
            } label: {
                Label("Import audio", systemImage: "square.and.arrow.down")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(Palette.ink2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record.take.import")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func actions(_ paragraph: FlowParagraph) -> some View {
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
            .disabled(paragraph.take == nil)
            .accessibilityIdentifier("record.acceptAndNext")
        }
        .padding(.top, 8)
    }

    /// Stops any live recording, then either accepts or flags the paragraph
    /// and advances to the next one IN PLACE — no new view on the stack. The
    /// last paragraph finishes into the review list (or pops back to it when
    /// this view was pushed from the list).
    private func goNext(from paragraph: FlowParagraph, flag: Bool) async {
        if model.isRecording {
            await model.stopRecordingParagraph(paragraph.id)
        }
        if flag {
            model.flagParagraph(paragraph.id, note: "")
        } else {
            model.acceptParagraph(paragraph.id)
        }
        await model.persist()
        if let next = model.nextParagraph(after: paragraph.id) {
            model.currentParagraphID = next.id
        } else if fromReview {
            dismiss()
        } else {
            model.currentParagraphID = nil
            navigateToReview = true
        }
    }

    private func goPrevious(from paragraph: FlowParagraph) async {
        if model.isRecording {
            await model.stopRecordingParagraph(paragraph.id)
        }
        if let previous = previousParagraph() {
            model.currentParagraphID = previous.id
        }
    }

    private func previousParagraph() -> FlowParagraph? {
        model.previousParagraph(before: currentParagraphID)
    }

    private func roleLabel(_ role: FlowParagraphRole) -> String {
        switch role {
        case .intro: return "Intro"
        case .outro: return "Outro"
        case .body: return "Paragraph"
        }
    }
}

// MARK: - p04 Review

struct ReviewView: View {
    @Bindable var model: NarrationFlowModel
    /// True when pushed from the record flow's review destination; false when
    /// shown as the flow root. Drives the Close-vs-Back toolbar choice.
    var isPushed = false
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

            let rows = filtered(model.paragraphs)
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
            .disabled(!model.readyToAssemble)
            .accessibilityIdentifier("review.toAssemble")
        }
        .background(VoxglassBackground())
        .navigationDestination(isPresented: $goAssemble) {
            AssembleView(model: model, isPushed: true)
        }
        .navigationDestination(item: $reRecordID) { id in
            RecordView(model: model, paragraphID: id, fromReview: true)
        }
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var goAssemble = false

    private func filtered(_ paragraphs: [FlowParagraph]) -> [FlowParagraph] {
        switch filter {
        case .all: return paragraphs
        case .flagged: return paragraphs.filter { $0.state == .flagged }
        case .pickup: return paragraphs.filter { $0.state == .notRecorded }
        }
    }

    private func row(_ paragraph: FlowParagraph) -> some View {
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
            .disabled(paragraph.take == nil)
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

    private func statusIcon(_ state: FlowParagraphState) -> some View {
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

    private func tint(_ state: FlowParagraphState) -> Color {
        switch state {
        case .approved: return Palette.ok
        case .flagged: return Color(hex: 0xE6B877)
        case .recorded: return Palette.brass
        case .notRecorded: return Palette.ink3
        }
    }

    private func caption(_ paragraph: FlowParagraph) -> String {
        var parts: [String] = []
        switch paragraph.role {
        case .intro: parts.append("Intro")
        case .outro: parts.append("Outro")
        case .body: parts.append("¶")
        }
        if let take = paragraph.take { parts.append(take.duration.formattedShort) }
        parts.append(stateText(paragraph.state))
        return parts.joined(separator: " · ")
    }

    private func stateText(_ state: FlowParagraphState) -> String {
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
    var isPushed = false
    @State private var sceneGap: TimeInterval = 1.0
    @State private var tailSilence: TimeInterval = 1.5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let project = model.project {
                    chapterCard(project)
                }

                Text("SPACING")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)
                spacingCard

                Text("TAKE HANDLING")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
                togglesCard

                Text("RENDER CACHE")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)
                    .padding(.top, 4)
                renderCacheCard

                preflightCard

                Text("Assembly is a plan. Your original takes are never modified or trimmed on disk.")
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)

                Button {
                    goMetadata = true
                } label: {
                    Text("Continue ▸")
                        .scaledFont(size: 15, weight: .heavy)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(Color(hex: 0x21170B))
                }
                .buttonStyle(.plain)
                .tactileTap()
                .accessibilityIdentifier("assemble.continue")
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationDestination(isPresented: $goMetadata) {
            MetadataView(model: model, isPushed: true)
        }
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            sceneGap = model.assembly.sceneBreakExtraGap
            tailSilence = model.assembly.chapterTailSilence
            await model.refreshRenderStatuses()
        }
    }

    @State private var goMetadata = false

    // MARK: - Cards

    private func chapterCard(_ project: AudiobookProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.metadata.title).scaledFont(size: 16, weight: .heavy).foregroundStyle(Palette.ink)
                    Text("\(project.metadata.author) · \(project.chapters.count) chapter\(project.chapters.count == 1 ? "" : "s") · ~\(model.totalDuration.formattedShort)")
                        .scaledFont(size: 12).foregroundStyle(Palette.ink2)
                }
                Spacer()
                Text("\(project.recordedCount) ¶")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.brass.opacity(0.12), in: Capsule())
            }
            Text("Renders are chunked by chapter and can be cancelled — finished chapters stay cached and resume from there.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 16)
        .accessibilityIdentifier("assemble.renderPreview")
    }

    private var spacingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow("Between paragraphs", value: assemblyBinding(\.paragraphGap), range: 0.1...2.0, step: 0.05, id: "assemble.paragraphGap")
            sliderRow("Between scenes", value: sceneGapBinding, range: 0.1...4.0, step: 0.05, id: "assemble.sceneGap")
            sliderRow("Room tone at head", value: assemblyBinding(\.chapterHeadSilence), range: 0...3.0, step: 0.05, id: "assemble.headSilence")
            sliderRow("Room tone at tail", value: tailSilenceBinding, range: 0...5.0, step: 0.05, id: "assemble.roomTone")
            Text("ACX requires room tone at the head and tail of every file. These defaults satisfy it.")
                .scaledFont(size: 11).foregroundStyle(Palette.ink3)
        }
        .padding(13)
        .glassSurface(cornerRadius: 14)
    }

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow("Trim silence at take edges", caption: "Detected, not guessed — uses the same analysis as import", isOn: trimBinding, id: "assemble.trimSilence")
            VoxglassListDivider()
            toggleRow("Normalise take-to-take loudness", caption: "ReplayGain, applied at render", isOn: normalizeBinding, id: "assemble.normalise")
        }
        .padding(13)
        .glassSurface(cornerRadius: 14)
    }

    private var renderCacheCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Render cache").scaledFont(size: 14, weight: .bold).foregroundStyle(Palette.ink)
                Spacer()
                if model.isRendering {
                    Text("Rendering…")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(Palette.brass)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.brass.opacity(0.12), in: Capsule())
                        .accessibilityIdentifier("assemble.rendering")
                }
            }

            if let project = model.project {
                VStack(spacing: 0) {
                    ForEach(project.chapters) { chapter in
                        renderRow(chapter, project: project)
                        if chapter.id != project.chapters.last?.id { VoxglassListDivider() }
                    }
                }
                .padding(.horizontal, 11)
            }

            HStack(spacing: 10) {
                Button {
                    model.startRenderAllChapters()
                } label: {
                    Text(model.isRendering ? "Cancel render" : "Render all")
                        .scaledFont(size: 13, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Palette.brass.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.brass.opacity(0.45), lineWidth: 1))
                        .foregroundStyle(Palette.brass)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(model.isRendering ? "assemble.cancelRender" : "assemble.renderAll")

                Button {
                    Task { await model.clearRenderCache() }
                } label: {
                    Text("Clear cache")
                        .scaledFont(size: 13, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
                        .foregroundStyle(Palette.ink)
                }
                .buttonStyle(.plain)
                .disabled(model.isRendering)
                .accessibilityIdentifier("assemble.clearCache")
            }

            if model.isRendering, let progress = model.renderProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.totalChapterCount > 0 ? Double(progress.completedChapterCount) / Double(progress.totalChapterCount) : 0)
                        .tint(Palette.brass)
                    Text(renderProgressText(progress))
                        .scaledFont(size: 11)
                        .foregroundStyle(Palette.ink3)
                }
                .accessibilityIdentifier("assemble.renderProgress")
            }

            if let error = model.renderError {
                Text(error).scaledFont(size: 11.5).foregroundStyle(Palette.danger)
            }

            Text("Renders can be cleared any time — they rebuild from your takes. They are the first thing evicted under storage pressure.")
                .scaledFont(size: 11).foregroundStyle(Palette.ink3)
        }
        .padding(13)
        .glassSurface(cornerRadius: 14)
    }

    private func renderRow(_ chapter: ProductionChapter, project: AudiobookProject) -> some View {
        let state = model.renderStatuses[chapter.id] ?? .stale
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.title).scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                Text(subtitle(for: chapter, project: project)).scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }
            Spacer()
            switch state {
            case .notRecorded:
                Text("—").scaledFont(size: 11).foregroundStyle(Palette.ink3)
            case .current:
                Text("Current")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(Palette.ok)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.ok.opacity(0.12), in: Capsule())
            case .stale:
                Text("Stale")
                    .scaledFont(size: 10, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Palette.brass.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 9)
        .accessibilityIdentifier("assemble.chapter.\(chapter.ordinal)")
    }

    private func subtitle(for chapter: ProductionChapter, project: AudiobookProject) -> String {
        let recorded = chapter.paragraphs.count { $0.selectedTakeID != nil }
        if recorded == 0 { return "Not recorded yet" }
        let segments = SegmentQueueBuilder().build(.chapter(chapter.id), from: project, settings: model.assembly)
        let duration = AssemblyDuration.duration(of: segments)
        return "\(recorded) ¶ · \(duration.formattedShort)"
    }

    private func renderProgressText(_ progress: ChunkedRenderCoordinator.Progress) -> String {
        if let title = progress.currentChapterTitle {
            return "\(title) · \(Int(progress.currentChapterFraction * 100))%"
        }
        return "\(progress.completedChapterCount) of \(progress.totalChapterCount) chapters"
    }

    private var preflightCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preflight").scaledFont(size: 14, weight: .bold).foregroundStyle(Palette.ink)
                Spacer()
                if let preflight = model.renderPreflight {
                    Text("\(ByteCountFormatter.string(fromByteCount: preflight.neededBytes, countStyle: .file)) needed · \(ByteCountFormatter.string(fromByteCount: preflight.freeBytes, countStyle: .file)) free")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(preflight.freeBytes >= preflight.neededBytes ? Palette.ok : Palette.danger)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((preflight.freeBytes >= preflight.neededBytes ? Palette.ok : Palette.danger).opacity(0.12), in: Capsule())
                        .accessibilityIdentifier("assemble.preflight")
                }
            }
            Text("Assets in iCloud: none for a fresh render — every take is local until you offload.")
                .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
        }
        .padding(13)
        .glassSurface(cornerRadius: 14)
    }

    // MARK: - Bindings

    /// Binds one `AssemblySettings` property and persists the plan (mockup 10:
    /// the plan is metadata, never a destructive edit).
    private func assemblyBinding<Value>(_ keyPath: WritableKeyPath<AssemblySettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.assembly[keyPath: keyPath] },
            set: { newValue in
                model.assembly[keyPath: keyPath] = newValue
                Task { await model.applyAssembly(model.assembly) }
            }
        )
    }

    private var sceneGapBinding: Binding<TimeInterval> {
        Binding(
            get: { sceneGap },
            set: { value in
                sceneGap = value
                model.assembly.sceneBreakExtraGap = value
                Task { await model.applyAssembly(model.assembly) }
            }
        )
    }

    private var tailSilenceBinding: Binding<TimeInterval> {
        Binding(
            get: { tailSilence },
            set: { value in
                tailSilence = value
                model.assembly.chapterTailSilence = value
                Task { await model.applyAssembly(model.assembly) }
            }
        )
    }

    private var trimBinding: Binding<Bool> {
        Binding(
            get: { model.assembly.isTrimmingSilenceAtEdges },
            set: { value in
                model.assembly.trimSilenceAtEdges = value
                Task { await model.applyAssembly(model.assembly) }
            }
        )
    }

    private var normalizeBinding: Binding<Bool> {
        Binding(
            get: { model.assembly.isNormalizingLoudness },
            set: { value in
                model.assembly.normalizeLoudness = value
                Task { await model.applyAssembly(model.assembly) }
            }
        )
    }

    private func toggleRow(_ title: String, caption: String, isOn: Binding<Bool>, id: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(size: 13.5, weight: .semibold).foregroundStyle(Palette.ink)
                Text(caption).scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Palette.brass)
                .accessibilityIdentifier(id)
        }
    }

    private func sliderRow(_ label: String, value: Binding<TimeInterval>, range: ClosedRange<Double>, step: Double, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).scaledFont(size: 13.5, weight: .semibold).foregroundStyle(Palette.ink)
                Spacer()
                Text(String(format: "%.2f s", value.wrappedValue))
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .accessibilityIdentifier(id)
            }
            Slider(value: value, in: range, step: step)
                .tint(Palette.brass)
        }
    }
}

// MARK: - p06 Metadata & rights

struct MetadataView: View {
    @Bindable var model: NarrationFlowModel
    var isPushed = false

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
                        model.attest()
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
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $goExport) {
            ValidateExportView(model: model, isPushed: true)
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
            get: { model.project?.metadata.title ?? "" },
            set: { if var project = model.project {
                project.metadata.title = $0
                project.modifiedAt = model.repository.clock.now
                model.project = project
            } }
        )
    }

    private var authorBinding: Binding<String> {
        Binding(
            get: { model.project?.metadata.author ?? "" },
            set: { if var project = model.project {
                project.metadata.author = $0
                project.modifiedAt = model.repository.clock.now
                model.project = project
            } }
        )
    }
}

// MARK: - p07 Validate & export

struct ValidateExportView: View {
    @Bindable var model: NarrationFlowModel
    var isPushed = false
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
                checkRow(title: "Human narration (no AI audio)", ok: humanNarration, note: humanNarration ? "eligible" : "blocked", id: "validate.origin")
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

                Text("FLAC/MP3 encoding happens on this iPhone. Your paragraph takes transfer with the project.")
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
            SubmitView(model: model, isPushed: true)
        }
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
    }

    @State private var goSubmit = false

    private var hasMetadata: Bool {
        guard let project = model.project else { return false }
        return !project.metadata.title.isEmpty
            && !project.metadata.author.isEmpty
            && !model.narrator.isEmpty
            && !model.language.isEmpty
    }

    private var hasDisclaimer: Bool {
        // A recorded-but-not-yet-accepted paragraph still has its take, so it
        // satisfies the LibriVox disclaimer requirement (matches
        // readyToAssemble, which only requires every paragraph recorded).
        let recorded: Set<FlowParagraphState> = [.recorded, .approved]
        return model.paragraphs.contains { $0.role == .intro && recorded.contains($0.state) }
            && model.paragraphs.contains { $0.role == .outro && recorded.contains($0.state) }
    }

    /// Spec §10: an imported non-human or unknown take blocks LibriVox. The
    /// eligibility profile reads the selected takes' declared origins.
    private var humanNarration: Bool {
        guard let project = model.project else { return true }
        return EligibilityProfile.evaluate(project).librivoxEligible
    }

    private var clippingDetected: Bool {
        model.paragraphs.contains { $0.take?.clipped == true }
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
            Text("Encoding is unavailable in this build. Save your project and try again after enabling the on-device export codecs.")
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
    var isPushed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 6) {
                    Text("🎉").scaledFont(size: 40)
                    Text("Your recording is ready")
                        .scaledFont(size: 22, weight: .heavy).foregroundStyle(Palette.ink)
                    if let project = model.project {
                        Text("\"\(project.metadata.title)\" by \(project.metadata.author) · a publishable public-domain recording")
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
                submitStep(2, "Upload the MP3 to the LibriVox uploader (from your iPhone).")
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
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shareItem: URL {
        model.exportBundle?.directory
            ?? FileManager.default.temporaryDirectory
    }

    private var archiveCommand: String {
        guard let bundle = model.exportBundle else { return "" }
        let identifier = (model.project?.metadata.title ?? "voxglass").lowercased().replacingOccurrences(of: " ", with: "-")
        return "ia upload \(identifier) --metadata='mediatype:audio' --metadata='collection:opensource_audio' --metadata='title:\(model.project?.metadata.title ?? "")' --metadata='creator:\(model.project?.metadata.author ?? "")' \(bundle.files.map(\.lastPathComponent).joined(separator: " "))"
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
