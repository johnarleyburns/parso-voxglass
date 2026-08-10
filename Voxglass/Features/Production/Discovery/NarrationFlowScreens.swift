import SwiftUI
import MediaPlayer
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
                            .fill(LinearGradient(colors: [NarrationPalette.forestDeep, NarrationPalette.forest], startPoint: .top, endPoint: .bottom))
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
                        .foregroundStyle(NarrationPalette.espresso)
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
    /// The media-button claim for this armed session (spec §9.3), removed on
    /// disappear so the consumer player's claim is untouched outside recording.
    @State private var mediaButtonToken: Any?

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
        .onAppear {
            // The recording remote (mockup watch-04, §14.3) is live for the
            // whole time the record screen is on screen.
            model.beginRecordingRemoteSession()
            claimMediaButton()
        }
        .onDisappear {
            model.endRecordingRemoteSession()
            releaseMediaButton()
            if model.isRecording {
                Task { await model.stopRecordingParagraph(currentParagraphID) }
            }
        }
        .navigationDestination(isPresented: $navigateToReview) {
            ReviewView(model: model, isPushed: true)
        }
        .sheet(isPresented: $showAudioSetup) {
            AudioSetupView(capture: model.capture)
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
            .accessibilityLabel("Play the take for this paragraph in context")

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
            .accessibilityLabel(model.isRecording ? "Stop recording this take" : "Record a take for this paragraph")
            // §9.3 external controls: a connected hardware keyboard records and
            // stops with Command-R while the record screen is armed.
            .keyboardShortcut("r", modifiers: [.command])

            Button {
                model.play(currentParagraphID)
            } label: {
                Image(systemName: "play.circle.fill").scaledFont(size: 40)
            }
            .foregroundStyle(Palette.ink2)
            .disabled(model.paragraph(at: currentParagraphID)?.take == nil)
            .accessibilityIdentifier("record.transport.playTake")
            .accessibilityLabel("Play back the latest take for this paragraph")
        }
        .padding(.vertical, 10)
    }

    private func takesRow(_ paragraph: FlowParagraph) -> some View {
        HStack(spacing: 8) {
            if let take = paragraph.take {
                Text("Take · \(take.duration.formattedShort)")
                    .scaledFont(size: 11, weight: .semibold)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .foregroundStyle(NarrationPalette.nearBlack)
                    .background(NarrationPalette.cream, in: Capsule())
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
                    .foregroundStyle(NarrationPalette.brassSoft)
                    .frame(width: 54, height: 46)
                    .background(NarrationPalette.brassMid.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(NarrationPalette.brassMid.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record.flagAndNext")
            .accessibilityLabel("Flag this paragraph for review and go to the next paragraph")

            Button {
                Task { await goNext(from: paragraph, flag: false) }
            } label: {
                Text("Accept & Next ▸")
                    .scaledFont(size: 14, weight: .heavy)
                    .foregroundStyle(NarrationPalette.espresso)
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

    // MARK: - External controls (§9.3)

    /// Maps the Bluetooth media button / headset stem to Record/Stop while this
    /// record screen is armed. The consumer player's own `togglePlayPauseCommand`
    /// target stays registered and is inert here (no consumer playback is active
    /// during a session); removing this claim on disappear restores the player's
    /// exclusive use of the button outside recording — listening is never
    /// degraded.
    private func claimMediaButton() {
        guard mediaButtonToken == nil else { return }
        mediaButtonToken = MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { [weak model] _ in
            guard let model, let paragraphID = model.currentParagraphID else { return .commandFailed }
            if model.isRecording {
                Task { @MainActor in await model.stopRecordingParagraph(paragraphID) }
            } else {
                Task { @MainActor in await model.startRecordingParagraph(paragraphID) }
            }
            return .success
        }
    }

    private func releaseMediaButton() {
        guard let token = mediaButtonToken else { return }
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(token)
        mediaButtonToken = nil
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
                    .foregroundStyle(NarrationPalette.espresso)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
            .buttonStyle(.plain)
            .disabled(!model.readyToAssemble)
            .accessibilityIdentifier("review.toAssemble")
        }
        .background(VoxglassBackground())
        .task { await model.refreshRemoteAssetStates() }
        .alert("Couldn't download this recording", isPresented: hydrationErrorPresented) {
            Button("OK", role: .cancel) { model.hydrationError = nil }
        } message: {
            Text(model.hydrationError ?? "")
        }
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

    private var hydrationErrorPresented: Binding<Bool> {
        Binding(
            get: { model.hydrationError != nil },
            set: { if !$0 { model.hydrationError = nil } }
        )
    }

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
                    Text(note).scaledFont(size: 11).foregroundStyle(NarrationPalette.tan)
                }
            }
            Spacer()
            if let bytes = paragraph.remoteTakeByteCount {
                Button {
                    Task { await model.hydrateForPlayback(paragraph.id) }
                } label: {
                    HStack(spacing: 5) {
                        if model.hydratingParagraphID == paragraph.id {
                            ProgressView().controlSize(.small).tint(Palette.brass)
                        } else {
                            Image(systemName: "icloud.and.arrow.down").scaledFont(size: 12, weight: .semibold)
                        }
                        Text(model.hydratingParagraphID == paragraph.id ? "Downloading" : byteEstimate(bytes))
                            .scaledFont(size: 11, weight: .bold)
                    }
                    .foregroundStyle(Palette.brass)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Palette.brass.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Palette.brass.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.hydratingParagraphID != nil && model.hydratingParagraphID != paragraph.id)
                .accessibilityIdentifier("paragraphList.hydrate")
            } else {
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
            }

            if paragraph.state == .flagged {
                Button("Re-record ▸") {
                    // Target the tapped paragraph: `currentParagraphID` may be
                    // stale after the flow routed to review, and RecordView
                    // prefers it over its `paragraphID` argument.
                    model.currentParagraphID = paragraph.id
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
        case .flagged: return NarrationPalette.brassSoft
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

    private func byteEstimate(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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
                        .foregroundStyle(NarrationPalette.espresso)
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
                        Text("IA").scaledFont(size: 9, weight: .heavy).foregroundStyle(NarrationPalette.sky)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(NarrationPalette.sky.opacity(0.14), in: Capsule())
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
                        .foregroundStyle(NarrationPalette.espresso)
                }
                .buttonStyle(.plain)
                .disabled(!model.rightsAttested)
                .accessibilityIdentifier("metadata.toExport")
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
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
                .background(NarrationPalette.panelInk, in: RoundedRectangle(cornerRadius: 11))
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
                .background(NarrationPalette.panelInk, in: RoundedRectangle(cornerRadius: 11))
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
    @State private var goSubmit = false
    @State private var showAudioSetup = false
    @State private var showProPurchase = false
    @State private var showExportRun = false
    @State private var showChapterPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("WHAT TO EXPORT")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)

                scopePicker

                Text("PUBLISH TO")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)

                VStack(spacing: 0) {
                    destinationRow(.librivox, label: "LibriVox", subtitle: "128 kbps MP3 per section", id: "validation.destination.librivox")
                    VoxglassListDivider()
                    destinationRow(.internetArchive, label: "Internet Archive", subtitle: "FLAC masters + MP3 derivatives", id: "validation.destination.internetArchive")
                    VoxglassListDivider()
                    destinationRow(.acx, label: "Commercial retail", subtitle: "ACX, Apple Books, aggregator, M4B", id: "validation.destination.retail", proChip: true)
                }
                .glassSurface(cornerRadius: 14)
                .accessibilityIdentifier("validation.destination")

                if model.isValidating {
                    HStack(spacing: 8) {
                        ProgressView().tint(Palette.brass)
                        Text("Checking \(destinationName)…").scaledFont(size: 12).foregroundStyle(Palette.ink2)
                    }
                    .padding(.vertical, 10)
                } else {
                    let blocking = model.blockingValidationIssues
                    let warnings = model.validationIssues.filter { $0.severity == .warning }

                    HStack {
                        Text("\(destinationName)")
                            .scaledFont(size: 15, weight: .heavy).foregroundStyle(Palette.ink)
                        Spacer()
                        Text("\(blocking.count) blocking · \(warnings.count) warnings")
                            .scaledFont(size: 11, weight: .bold).foregroundStyle(blocking.isEmpty ? Palette.ok : Palette.danger)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((blocking.isEmpty ? Palette.ok : Palette.danger).opacity(0.14), in: Capsule())
                    }
                    .accessibilityIdentifier("validate.report")

                    if !blocking.isEmpty {
                        issueSection(title: "BLOCKS EXPORT", issues: blocking)
                    }
                    if !warnings.isEmpty {
                        issueSection(title: "WARNINGS", issues: warnings)
                    }
                    if blocking.isEmpty && warnings.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill").scaledFont(size: 15, weight: .bold).foregroundStyle(Palette.ok)
                            Text("Ready to export — every check passed for \(destinationName).")
                                .scaledFont(size: 12.5).foregroundStyle(Palette.ink2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(cornerRadius: 14)
                    }
                }

                if let preflight = model.preflight, preflight.hydrationPlan.byteCount > 0 {
                    hydrationBanner(preflight)
                }

                if let error = model.exportError {
                    Text(error).scaledFont(size: 12).foregroundStyle(Palette.danger).padding(.top, 4)
                }

                Button {
                    showExportRun = true
                    model.startExport()
                } label: {
                    HStack(spacing: 8) {
                        if model.isExporting {
                            ProgressView().tint(NarrationPalette.espresso)
                        }
                        Text(model.isExporting ? "Producing files…" : "Produce files ▸")
                            .scaledFont(size: 15, weight: .heavy)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(NarrationPalette.espresso)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!hasMetadata || !model.blockingValidationIssues.isEmpty || model.isExporting || !model.exportScopeIsValid)
                .accessibilityIdentifier("validation.continueToExport")

                Text("FLAC/MP3 encoding happens on this iPhone. Validation and export are free for LibriVox and Internet Archive.")
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .task { await model.runValidation() }
        .onChange(of: model.exportBundle) { _, newValue in
            if newValue != nil { goSubmit = true }
        }
        .sheet(isPresented: $showAudioSetup) {
            AudioSetupView(capture: model.capture)
        }
        .sheet(isPresented: $showChapterPicker) {
            chapterPickerSheet
        }
        .sheet(isPresented: $showProPurchase) {
            ProPurchaseView(provider: model.licenseProvider, model: model) { _ in
                Task { await model.runValidation() }
            }
        }
        .fullScreenCover(isPresented: $showExportRun) {
            ExportRunView(model: model) {
                showExportRun = false
                goSubmit = true
            }
        }
        .navigationDestination(isPresented: $goSubmit) {
            SubmitView(model: model, isPushed: true)
        }
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasMetadata: Bool {
        guard let project = model.project else { return false }
        return !project.metadata.title.isEmpty
            && !project.metadata.author.isEmpty
            && !model.narrator.isEmpty
            && !model.language.isEmpty
    }

    private var destinationName: String {
        switch model.validationDestination {
        case .internetArchive: return "Internet Archive"
        case .acx: return "ACX / Audible"
        case .appleBooksAggregator: return "Apple Books / Aggregator"
        default: return "LibriVox"
        }
    }

    // MARK: Export scope (mockup 14 "WHAT TO EXPORT", §13.2 step 1)

    /// The four spec'd scope choices. Every row maps onto `ExportScope` via the
    /// model; "Selected chapters" opens the chapter picker. NOTE: no container
    /// identifier — a plain container's id overrides every child's (SwiftUI
    /// quirk), which would collapse `export.scope.chapter` etc. into
    /// `export.scope`.
    private var scopePicker: some View {
        VStack(spacing: 0) {
            scopeRow(.currentChapter, subtitle: currentChapterSubtitle)
            VoxglassListDivider()
            scopeRow(.selectedChapters, subtitle: selectedChaptersSubtitle)
            VoxglassListDivider()
            scopeRow(.wholeBook, subtitle: wholeBookSubtitle)
            VoxglassListDivider()
            scopeRow(.reviewQueue, subtitle: reviewQueueSubtitle)
        }
        .glassSurface(cornerRadius: 14)
    }

    private func scopeRow(_ choice: ExportScopeSelection, subtitle: String) -> some View {
        let selected = model.exportScopeChoice == choice
        let disabled = scopeDisabled(choice)
        return Button {
            if choice == .selectedChapters {
                showChapterPicker = true
            } else {
                model.selectExportScope(choice)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(selected ? Palette.brass : Palette.ink3)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title).scaledFont(size: 13.5, weight: selected ? .heavy : .semibold)
                        .foregroundStyle(disabled ? Palette.ink3 : Palette.ink)
                    Text(subtitle).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                }
                Spacer()
                if choice == .selectedChapters {
                    Image(systemName: "chevron.right").scaledFont(size: 11).foregroundStyle(Palette.ink3)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(scopeID(choice))
    }

    private func scopeDisabled(_ choice: ExportScopeSelection) -> Bool {
        switch choice {
        case .currentChapter: return model.project?.chapters.isEmpty ?? true
        case .selectedChapters: return model.project?.chapters.isEmpty ?? true
        case .reviewQueue: return !model.exportScopeIsValid
        case .wholeBook: return false
        }
    }

    private func scopeID(_ choice: ExportScopeSelection) -> String {
        switch choice {
        case .currentChapter: return "export.scope.chapter"
        case .selectedChapters: return "export.scope.selected"
        case .wholeBook: return "export.scope.whole"
        case .reviewQueue: return "export.scope.queue"
        }
    }

    private var currentChapterSubtitle: String {
        guard let project = model.project, let id = model.currentExportChapterID,
              let chapter = project.chapters.first(where: { $0.id == id }) else {
            return model.project?.chapters.isEmpty == false ? "\(model.project?.chapters.first?.title ?? "Chapter 1")" : "No chapters yet"
        }
        return chapter.title + " · " + PackagingSupport.clockTime(chapterDuration(chapter))
    }

    private var selectedChaptersSubtitle: String {
        let count = model.exportSelectedChapterIDs.count
        return count == 0 ? "Pick from a list" : "\(count) chapter\(count == 1 ? "" : "s")"
    }

    private var wholeBookSubtitle: String {
        guard let project = model.project else { return "" }
        return "\(project.chapters.count) chapter\(project.chapters.count == 1 ? "" : "s") · " + PackagingSupport.clockTime(model.totalDuration)
    }

    private var reviewQueueSubtitle: String {
        guard let project = model.project else { return "No flagged paragraphs" }
        let flagged = project.allParagraphs.count { $0.reviewState == .flagged }
        return flagged == 0 ? "No flagged paragraphs" : "\(flagged) flagged paragraph\(flagged == 1 ? "" : "s")"
    }

    private func chapterDuration(_ chapter: ProductionChapter) -> TimeInterval {
        chapter.paragraphs.reduce(0) { $0 + ($1.selectedTake?.duration ?? 0) }
    }

    private var chapterPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(model.project?.chapters ?? []) { chapter in
                    Button {
                        toggleChapterSelection(chapter.id)
                    } label: {
                        HStack {
                            Image(systemName: model.exportSelectedChapterIDs.contains(chapter.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(model.exportSelectedChapterIDs.contains(chapter.id) ? Palette.brass : Palette.ink3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title).scaledFont(size: 13.5, weight: .semibold).foregroundStyle(Palette.ink)
                                Text("\(chapter.paragraphs.count) paragraph\(chapter.paragraphs.count == 1 ? "" : "s") · " + PackagingSupport.clockTime(chapterDuration(chapter)))
                                    .scaledFont(size: 11).foregroundStyle(Palette.ink3)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("export.chapter.\(chapter.ordinal)")
                }
            }
            .navigationTitle("Selected chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showChapterPicker = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        showChapterPicker = false
                        model.selectExportScope(.selectedChapters)
                    }
                    .accessibilityIdentifier("export.chapters.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleChapterSelection(_ chapterID: UUID) {
        if model.exportSelectedChapterIDs.contains(chapterID) {
            model.exportSelectedChapterIDs.remove(chapterID)
        } else {
            model.exportSelectedChapterIDs.insert(chapterID)
        }
    }

    /// A full-width destination row (mockup 14). Retail carries a Pro chip and is
    /// the only destination that consults `LicenseGate` — the destination-picker
    /// gate placement (§2.2). Tapping locked retail opens the purchase sheet.
    private func destinationRow(_ destination: DestinationID, label: String, subtitle: String, id: String, proChip: Bool = false) -> some View {
        let selected = model.validationDestination == destination
        let isRetail = destination == .acx || destination == .appleBooksAggregator
        let unlocked = !isRetail || model.isProUnlocked
        return Button {
            if unlocked {
                model.selectValidationDestination(destination)
            } else {
                showProPurchase = true
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label).scaledFont(size: 13.5, weight: selected ? .heavy : .semibold)
                            .foregroundStyle(selected ? Palette.ink : Palette.ink2)
                        if proChip {
                            Text("Pro")
                                .scaledFont(size: 10, weight: .bold)
                                .foregroundStyle(model.isProUnlocked ? Palette.ok : Palette.brass)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background((model.isProUnlocked ? Palette.ok : Palette.brass).opacity(0.14), in: Capsule())
                                .overlay(Capsule().stroke((model.isProUnlocked ? Palette.ok : Palette.brass).opacity(0.4), lineWidth: 1))
                        }
                    }
                    Text(subtitle).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").scaledFont(size: 15, weight: .bold).foregroundStyle(Palette.brass)
                } else if !unlocked {
                    Image(systemName: "lock.fill").scaledFont(size: 13).foregroundStyle(Palette.ink3)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func issueSection(title: String, issues: [ValidationIssue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ink3)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(issueRows(issues).enumerated()), id: \.element.issue.id) { index, row in
                    issueRow(row.issue, id: row.id, index: index)
                }
            }
            .glassSurface(cornerRadius: 14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hairline, lineWidth: 1))
        }
    }

    /// Assigns each issue a stable `validation.issue.<key>` identifier, the
    /// mockup 13 contract; repeated codes get `.N` suffixes so rows stay
    /// addressable.
    private func issueRows(_ issues: [ValidationIssue]) -> [(issue: ValidationIssue, id: String)] {
        var counts: [String: Int] = [:]
        return issues.map { issue in
            let key = Self.issueKey(issue.code)
            let ordinal = (counts[key] ?? 0) + 1
            counts[key] = ordinal
            let base = Self.issueIDs[issue.code] ?? "validation.issue.generic"
            return (issue, ordinal == 1 ? base : "\(base).\(ordinal)")
        }
    }

    private func issueRow(_ issue: ValidationIssue, id: String, index: Int) -> some View {
        let danger = issue.severity == .blocking
        return VStack(spacing: 0) {
            if index > 0 { VoxglassListDivider() }
            HStack(spacing: 10) {
                Image(systemName: danger ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(danger ? Palette.danger : Palette.brass)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title).scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                    Text(issue.message).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                        .lineLimit(2)
                }
                Spacer()
                if let fix = issue.fix {
                    Button {
                        apply(fix)
                    } label: {
                        Text(fixLabel(fix))
                            .scaledFont(size: 11, weight: .bold)
                            .foregroundStyle(Palette.brass)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Palette.brass.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Palette.brass.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
        }
        .accessibilityIdentifier(id)
    }

    private func apply(_ fix: FixAction) {
        switch fix {
        case .openAudioSetup:
            showAudioSetup = true
        case .hydrateAssets, .backupNow, .manageStorage, .recordParagraph, .clearPickup, .goToParagraph, .goToChapter,
             .openMetadata, .openRights, .regenerateDisclaimers, .regenerateCredits, .selectTake, .chooseArtwork,
             .setRetailSample, .reanalyzeTake, .splitChapter, .applyMastering:
            break
        }
    }

    private func fixLabel(_ fix: FixAction) -> String {
        switch fix {
        case .hydrateAssets: return "Download"
        case .manageStorage: return "Storage"
        case .backupNow: return "Back up"
        case .openAudioSetup: return "Audio setup"
        case .recordParagraph: return "Record"
        case .clearPickup: return "Clear"
        case .regenerateDisclaimers, .regenerateCredits: return "Regenerate"
        case .reanalyzeTake: return "Re-analyze"
        case .setRetailSample: return "Sample"
        case .splitChapter: return "Split"
        case .chooseArtwork: return "Artwork"
        case .applyMastering: return "Master"
        case .goToParagraph, .goToChapter: return "Open"
        case .openMetadata: return "Edit"
        case .openRights: return "Rights"
        case .selectTake: return "Select"
        }
    }

    private func hydrationBanner(_ preflight: ExportPreflightResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "icloud.and.arrow.down").scaledFont(size: 15, weight: .bold).foregroundStyle(Palette.brass)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(preflight.remoteHydrationChapterCount) chapter\(preflight.remoteHydrationChapterCount == 1 ? "" : "s") are in iCloud")
                    .scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                Text("\(PackagingSupport.formattedBytes(preflight.hydrationPlan.byteCount)) must download before export can start.")
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
                HStack(spacing: 8) {
                    Button {
                        Task { await model.hydrateAllForExport() }
                    } label: {
                        Text("Download \(PackagingSupport.formattedBytes(preflight.hydrationPlan.byteCount))")
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(NarrationPalette.espresso)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .background(Palette.brass, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isValidating)
                    .accessibilityIdentifier("export.hydrateAll")

                    Button {
                        Task { await model.exportLocalOnly() }
                    } label: {
                        Text("Export the local chapters")
                            .scaledFont(size: 12, weight: .bold)
                            .foregroundStyle(Palette.brass)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .overlay(Capsule().stroke(Palette.brass.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isValidating || model.isExporting)
                    .accessibilityIdentifier("export.localOnly")
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.brass.opacity(0.45), lineWidth: 1))
        .accessibilityIdentifier("validation.issue.assetRemoteOnly")
    }

    /// The mockup's issue-key per code — the stable `validation.issue.<key>`
    /// identifier suffix (mockup 13). Literal values are the audit registry's
    /// contract.
    private static let issueIDs: [IssueCode: String] = [
        .unresolvedNeedsPickup: "validation.issue.needsPickup",
        .assetRemoteOnlyForExport: "validation.issue.assetRemoteOnly",
        .routeNotRetailReady: "validation.issue.routeNotRetailReady",
        .backupNotVerified: "validation.issue.backupNotVerified",
        .textChangedAfterRecording: "validation.issue.drift",
        .textChangedCosmetically: "validation.issue.drift",
        .artworkTooSmall: "validation.issue.artwork",
        .artworkNotSquare: "validation.issue.artwork",
        .missingCoverArt: "validation.issue.artwork",
    ]

    private static func issueKey(_ code: IssueCode) -> String {
        issueIDs[code] ?? "validation.issue.generic"
    }
}

// MARK: - p07b Export run & resume (screen 14b)

/// Full-screen progress for a resumable export run (mockup 14b, §13.3).
/// Runs are chunked by chapter and recorded in `ExportRunRecord`, so a relaunch
/// resumes at the first incomplete chapter rather than from zero; the reused
/// chapters are reported by `ResumableExportRunner` and shown as "kept".
struct ExportRunView: View {
    @Bindable var model: NarrationFlowModel
    /// Called when the run finishes with a package ready to hand off.
    var onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keepScreenOn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.exportReusedFileCount > 0 {
                        resumedBanner
                    }

                    progressCard

                    pipelineCard

                    chaptersCard

                    keepScreenOnCard

                    Text("If storage runs low mid-run the export pauses rather than failing, and tells you exactly how much to free.")
                        .scaledFont(size: 11.5)
                        .foregroundStyle(Palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassSurface(cornerRadius: 14)
                        .accessibilityIdentifier("exportRun.storageNote")

                    if !model.isExporting && model.exportBundle == nil {
                        terminalActions
                    }
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationTitle("Exporting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if model.isExporting {
                            model.cancelExport()
                        }
                        dismiss()
                    } label: {
                        Text("Close").scaledFont(size: 13).foregroundStyle(Palette.ink2)
                    }
                    .accessibilityIdentifier("exportRun.close")
                }
            }
        }
        .onChange(of: model.exportBundle) { _, newValue in
            if newValue != nil { onFinished() }
        }
        .onChange(of: keepScreenOn) { _, enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Resume banner

    private var resumedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Resumed where it stopped")
                    .scaledFont(size: 14, weight: .heavy).foregroundStyle(Palette.ok)
                Spacer()
                Text("\(model.exportReusedFileCount) chapters kept")
                    .scaledFont(size: 11, weight: .bold).foregroundStyle(Palette.ok)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Palette.ok.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Palette.ok.opacity(0.4), lineWidth: 1))
            }
            Text("Voxglass closed while another chapter was encoding. Chapters 1–\(model.exportReusedFileCount) were already finished and verified, so they were not re-rendered.")
                .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ok.opacity(0.45), lineWidth: 1))
        .accessibilityIdentifier("exportRun.resumed")
    }

    // MARK: Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Chapter \(currentChapter) of \(totalChapters)")
                    .scaledFont(size: 15, weight: .heavy).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(Int((model.exportProgress?.fractionCompleted ?? 0) * 100))%")
                    .scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.brass)
            }
            ProgressView(value: model.exportProgress?.fractionCompleted ?? 0, total: 1)
                .tint(Palette.brass)
                .accessibilityIdentifier("exportRun.progress")
            HStack(spacing: 0) {
                Text("Step")
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
                    .frame(width: 74, alignment: .leading)
                Text(stepText)
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("exportRun.step")
            }
            HStack(spacing: 0) {
                Text("Elapsed")
                    .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
                    .frame(width: 74, alignment: .leading)
                Text(elapsedText)
                    .scaledFont(size: 11.5, weight: .semibold).foregroundStyle(Palette.ink)
            }
            if let remaining = remainingText {
                HStack(spacing: 0) {
                    Text("Remaining")
                        .scaledFont(size: 11.5).foregroundStyle(Palette.ink3)
                        .frame(width: 74, alignment: .leading)
                    Text(remaining)
                        .scaledFont(size: 11.5, weight: .semibold).foregroundStyle(Palette.ink)
                }
            }

            if model.isExporting {
                Button {
                    model.cancelExport()
                } label: {
                    Text("Cancel after this chapter")
                        .scaledFont(size: 13, weight: .semibold)
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.danger.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("exportRun.cancel")
                Text("Cancelling never discards finished chapters — resuming later picks up from chapter \(min(currentChapter + 1, totalChapters)).")
                    .scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }

    private var terminalActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.exportError {
                Text(error).scaledFont(size: 12.5).foregroundStyle(Palette.danger)
            }
            Button {
                model.startExport()
            } label: {
                Text(model.exportRunRecord?.status == .cancelled ? "Resume export ▸" : "Try again ▸")
                    .scaledFont(size: 15, weight: .heavy)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(NarrationPalette.espresso)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("exportRun.resume")
        }
    }

    // MARK: Pipeline

    private var pipelineCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PIPELINE").scaledFont(size: 11, weight: .bold).foregroundStyle(Palette.ink3)
                .padding(.bottom, 2)
            pipelineRow(verified: true, step: "Hydrate chapters from iCloud", chip: "Verified")
            pipelineRow(verified: model.blockingValidationIssues.isEmpty, step: "Validate", chip: model.blockingValidationIssues.isEmpty ? "Passed" : nil)
            pipelineRow(step: "Render → transcode → tag", chip: running ? "\(min(currentChapter, totalChapters)) / \(totalChapters)" : (model.exportBundle != nil ? "Done" : "Interrupted"), active: running)
            pipelineRow(step: "Checksums")
            pipelineRow(step: "Checklist & package")
            pipelineRow(step: "Save to Files")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }

    private func pipelineRow(verified: Bool? = nil, step: String, chip: String? = nil, active: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: verified == true ? "checkmark" : (active ? "circle.fill" : "circle"))
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(verified == true ? Palette.ok : (active ? Palette.brass : Palette.ink3))
                .frame(width: 18)
            Text(step).scaledFont(size: 12.5).foregroundStyle(Palette.ink)
            Spacer()
            if let chip {
                Text(chip)
                    .scaledFont(size: 10.5, weight: .bold)
                    .foregroundStyle(active ? Palette.brass : (verified == true ? Palette.ok : Palette.ink2))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((active ? Palette.brass : (verified == true ? Palette.ok : Palette.ink2)).opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: Chapters

    private var chaptersCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CHAPTERS").scaledFont(size: 11, weight: .bold).foregroundStyle(Palette.ink3)
                .padding(.bottom, 2)
            if doneChapterCount > 0 {
                chapterRow(range: "1 – \(doneChapterCount)", chip: "Done", chipColor: Palette.ok)
            }
            if running {
                chapterRow(range: chapterLabel(currentChapter), chip: "Encoding", chipColor: Palette.brass)
            } else if model.exportBundle == nil && doneChapterCount > 0 {
                chapterRow(range: "\(doneChapterCount + 1) – \(totalChapters)", chip: "Queued", chipColor: nil)
            }
            if currentChapter < totalChapters {
                chapterRow(range: "\(currentChapter + 1) – \(totalChapters)", chip: "Queued", chipColor: nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }

    private func chapterRow(range: String, chip: String, chipColor: Color?) -> some View {
        HStack(spacing: 10) {
            Text(range).scaledFont(size: 12.5).foregroundStyle(Palette.ink)
            Spacer()
            Text(chip)
                .scaledFont(size: 10.5, weight: .bold)
                .foregroundStyle(chipColor ?? Palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((chipColor ?? Palette.ink2).opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 5)
    }

    // MARK: Keep screen on

    private var keepScreenOnCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep the screen on")
                    .scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                Text("Exports continue in the background, but finish faster in the foreground")
                    .scaledFont(size: 11).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Toggle("", isOn: $keepScreenOn)
                .labelsHidden()
                .tint(Palette.brass)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
        .accessibilityIdentifier("exportRun.keepAwake")
    }

    // MARK: Derived state

    private var running: Bool { model.isExporting }

    private var totalChapters: Int {
        if let p = model.exportProgress, p.totalUnits > 0 { return p.totalUnits }
        return max(model.project?.chapters.count ?? 0, 1)
    }

    private var currentChapter: Int {
        if model.exportBundle != nil { return totalChapters }
        let done = model.exportProgress?.completedUnits ?? 0
        return min(max(done + 1, 1), totalChapters)
    }

    /// Chapters finished in this run (or the kept set on a resumed run).
    private var doneChapterCount: Int {
        if model.exportReusedFileCount > 0 { return model.exportReusedFileCount }
        return model.exportProgress?.completedUnits ?? 0
    }

    private func chapterLabel(_ ordinal: Int) -> String {
        if let chapter = model.project?.chapters.first(where: { $0.ordinal == ordinal }), !chapter.title.isEmpty {
            return chapter.title
        }
        return "\(ordinal)"
    }

    private var stepText: String {
        guard let progress = model.exportProgress else {
            return model.isExporting ? "Preparing…" : "Preparing"
        }
        let file = progress.currentFileName.map { " \($0)" } ?? ""
        switch progress.phase {
        case .validating: return "Validating project…"
        case .rendering: return "Rendering\(file)"
        case .mastering: return "Mastering\(file)"
        case .transcoding: return "Encoding\(file)"
        case .tagging: return "Tagging\(file)"
        case .writingArtifacts: return "Writing\(file)"
        case .hashing: return "Hashing\(file)"
        case .chapterFinished: return "Chapter \(progress.completedUnits) of \(totalChapters) done"
        case .done: return "Package ready"
        }
    }

    private var elapsedText: String {
        guard let started = model.exportStartedAt else { return "—" }
        return Self.durationText(Date().timeIntervalSince(started))
    }

    private var remainingText: String? {
        if model.exportBundle != nil { return nil }
        if let remaining = model.exportProgress?.estimatedRemaining, remaining.isFinite, remaining > 0 {
            return "about \(Self.durationText(remaining))"
        }
        return nil
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%dm %02ds", minutes, seconds)
    }
}

// MARK: - p08 Submit & hand off

struct SubmitView: View {
    @Bindable var model: NarrationFlowModel
    var isPushed = false
    @Environment(\.dismiss) private var dismiss
    @State private var projectCopyURL: URL?

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
                        .foregroundStyle(NarrationPalette.espresso)
                }
                .accessibilityIdentifier("export.share")

                if let projectCopyURL {
                    ShareLink(item: projectCopyURL) {
                        Label("Save a copy of the project", systemImage: "shippingbox")
                            .scaledFont(size: 14, weight: .semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Palette.ink2.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hairline, lineWidth: 1))
                            .foregroundStyle(Palette.ink2)
                    }
                    .accessibilityIdentifier("project.saveCopy")
                }

                if model.exportRunRecord != nil {
                    Button {
                        Task { await model.evictLastExportStaging() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash").scaledFont(size: 13, weight: .semibold)
                            Text("Free the staging space")
                                .scaledFont(size: 13, weight: .semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Palette.ink2.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.ink2)
                    .accessibilityIdentifier("export.evictAfterSave")
                }

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
                        .foregroundStyle(NarrationPalette.skySoft)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(NarrationPalette.periwinkle.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NarrationPalette.periwinkle.opacity(0.4), lineWidth: 1))
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
        .task {
            // §4.4 "Save a copy": prepare the zipped .voxproject package once.
            if projectCopyURL == nil {
                projectCopyURL = await model.saveCopyOfProject()
            }
        }
        .narrationFlowBackOnlyToolbar(if: isPushed)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shareItem: URL {
        model.exportBundle?.shareURL
            ?? model.exportBundle?.directory
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
