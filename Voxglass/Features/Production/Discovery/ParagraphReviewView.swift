import SwiftUI
import VoxglassCore

/// The paragraph list's detail surface: listening, take choice, review state,
/// retakes and adjacent-paragraph navigation all live here.
struct ParagraphReviewView: View {
    @Bindable var model: NarrationFlowModel
    let paragraphID: UUID
    @State private var currentID: UUID
    @State private var reRecordID: UUID?
    @State private var showCompare = false
    @State private var showImport = false
    @State private var flagNote = ""
    @State private var showFlagSheet = false

    init(model: NarrationFlowModel, paragraphID: UUID) {
        self.model = model
        self.paragraphID = paragraphID
        _currentID = State(initialValue: paragraphID)
    }

    private var paragraph: FlowParagraph? { model.paragraph(at: currentID) }
    private var context: (chapterOrdinal: Int, number: Int, count: Int, role: ParagraphRole)? {
        model.paragraphContext(for: currentID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let paragraph {
                    header(paragraph)
                    Text(paragraph.text)
                        .scaledFont(size: 16, weight: .medium)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("paragraphReview.text")

                    if paragraph.isDrifted { driftBanner }
                    transport(paragraph)
                    takesCard
                    actions
                    adjacentNavigation
                } else {
                    ContentUnavailableView("Paragraph unavailable", systemImage: "text.badge.xmark")
                }
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .narrationFlowBackOnlyToolbar()
        .navigationDestination(item: $reRecordID) { id in
            RecordView(model: model, paragraphID: id, fromReview: true)
        }
        .sheet(isPresented: $showCompare) {
            TakeComparisonView(model: model, paragraphID: currentID)
        }
        .sheet(isPresented: $showImport) {
            ImportAudioView(model: model)
        }
        .sheet(isPresented: $showFlagSheet) { flagSheet }
        .onDisappear { model.stopPlayback() }
        .alert("Playback unavailable", isPresented: Binding(
            get: { model.playbackError != nil },
            set: { if !$0 { model.playbackError = nil } }
        )) {
            Button("OK", role: .cancel) { model.playbackError = nil }
        } message: {
            Text(model.playbackError ?? "")
        }
    }

    private func header(_ paragraph: FlowParagraph) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(context.map { "Chapter \($0.chapterOrdinal + 1) · ¶ \($0.number) of \($0.count)" } ?? "Paragraph review")
                .scaledFont(size: 16, weight: .heavy)
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier("paragraphReview.title")
            HStack(spacing: 8) {
                chip(roleName(context?.role), tint: Palette.ink2)
                chip(stateName(paragraph.state), tint: stateTint(paragraph.state))
                    .accessibilityIdentifier("paragraphReview.state")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 16)
    }

    private var driftBanner: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("The text changed after this was recorded", systemImage: "exclamationmark.triangle.fill")
                .scaledFont(size: 13, weight: .semibold)
            HStack {
                Button("Re-record") { openRecorder() }
                Button("Keep this take") { Task { await model.acceptDrift(paragraphID: currentID) } }
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(Palette.brass)
        .padding(12)
        .background(Palette.brass.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func transport(_ paragraph: FlowParagraph) -> some View {
        if let bytes = paragraph.remoteTakeByteCount {
            Button {
                Task { await model.hydrateForPlayback(currentID) }
            } label: {
                Label(model.hydratingParagraphID == currentID ? "Downloading…" : "Download \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "icloud.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .disabled(model.hydratingParagraphID != nil)
            .accessibilityIdentifier("paragraphReview.hydrate")
        } else {
            VStack(spacing: 8) {
                Button {
                    model.togglePlayback(currentID)
                } label: {
                    Label(isCurrentPlaying ? "Pause" : "Play take", systemImage: isCurrentPlaying ? "pause.fill" : "play.fill")
                        .scaledFont(size: 14, weight: .bold)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brass)
                .disabled(paragraph.take == nil)
                .accessibilityIdentifier(isCurrentPlaying ? "paragraphReview.pause" : "paragraphReview.play")

                if model.playbackParagraphID == currentID, model.playbackDuration > 0 {
                    Slider(value: Binding(
                        get: { model.playbackPosition },
                        set: { model.playbackPosition = $0; model.playbackPlayer?.currentTime = $0 }
                    ), in: 0...model.playbackDuration)
                    HStack {
                        Text(model.playbackPosition.formattedShort)
                        Spacer()
                        Text("-\(max(0, model.playbackDuration - model.playbackPosition).formattedShort)")
                    }
                    .scaledFont(size: 11, design: .monospaced)
                    .foregroundStyle(Palette.ink3)
                    .accessibilityIdentifier("paragraphReview.progress")
                }
            }
        }
    }

    private var takesCard: some View {
        let takes = model.takes(for: currentID)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("TAKES").scaledFont(size: 12, weight: .bold).foregroundStyle(Palette.ink3)
                Spacer()
                if takes.count >= 2 {
                    Button("Compare") { showCompare = true }
                        .scaledFont(size: 12, weight: .bold)
                        .accessibilityIdentifier("paragraphReview.compare")
                }
            }
            if takes.isEmpty {
                Text("No take yet").scaledFont(size: 13).foregroundStyle(Palette.ink3)
            }
            ForEach(Array(takes.enumerated()), id: \.element.id) { index, take in
                Button {
                    Task { await model.selectTake(take.id, for: currentID) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.selectedTakeID(for: currentID) == take.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Palette.brass)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Take \(index + 1) · \(take.duration.formattedShort)")
                                .scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                            Text(takeSubtitle(take))
                                .scaledFont(size: 11).foregroundStyle(Palette.ink3)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("paragraphReview.take.\(index)")
            }
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button("Approve") {
                    model.acceptParagraph(currentID)
                    Task { await model.persist() }
                }
                .accessibilityIdentifier("paragraphReview.approve")
                Button("Flag") { showFlagSheet = true }
                    .accessibilityIdentifier("paragraphReview.flag")
                Button("Re-record") { openRecorder() }
                    .accessibilityIdentifier("paragraphReview.rerecord")
            }
            .buttonStyle(.bordered)
            Button {
                showImport = true
            } label: {
                Label("Import audio", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("paragraphReview.import")
        }
    }

    private var adjacentNavigation: some View {
        HStack {
            Button("‹ Previous ¶") {
                if let previous = model.previousParagraph(before: currentID) { move(to: previous.id) }
            }
            .disabled(model.previousParagraph(before: currentID) == nil)
            .accessibilityIdentifier("paragraphReview.previous")
            Spacer()
            Button("Next ¶ ›") {
                if let next = model.nextParagraph(after: currentID) { move(to: next.id) }
            }
            .disabled(model.nextParagraph(after: currentID) == nil)
            .accessibilityIdentifier("paragraphReview.next")
        }
        .scaledFont(size: 13, weight: .bold)
    }

    private var flagSheet: some View {
        NavigationStack {
            Form { TextField("Note (optional)", text: $flagNote, axis: .vertical) }
                .navigationTitle("Flag paragraph")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showFlagSheet = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.flagParagraph(currentID, note: flagNote)
                            Task { await model.persist() }
                            showFlagSheet = false
                        }
                    }
                }
        }
        .presentationDetents([.medium])
    }

    private var isCurrentPlaying: Bool {
        model.playbackParagraphID == currentID && model.isPlayingTake
    }

    private func move(to id: UUID) {
        model.stopPlayback()
        currentID = id
        model.currentParagraphID = id
    }

    private func openRecorder() {
        model.stopPlayback()
        model.currentParagraphID = currentID
        reRecordID = currentID
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text).scaledFont(size: 11, weight: .bold)
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func roleName(_ role: ParagraphRole?) -> String {
        switch role {
        case .libriVoxIntro: "Intro"
        case .libriVoxOutro: "Outro"
        case .chapterHeading: "Chapter heading"
        case .retailOpeningCredits: "Opening credits"
        case .retailClosingCredits: "Closing credits"
        case .body, .none: "Body"
        }
    }

    private func stateName(_ state: FlowParagraphState) -> String {
        switch state {
        case .notRecorded: "Not recorded"
        case .recorded: "Recorded"
        case .approved: "Approved"
        case .flagged: "Flagged"
        }
    }

    private func stateTint(_ state: FlowParagraphState) -> Color {
        switch state {
        case .notRecorded: Palette.ink3
        case .recorded: Palette.brass
        case .approved: Palette.ok
        case .flagged: NarrationPalette.brassSoft
        }
    }

    private func takeSubtitle(_ take: Take) -> String {
        let origin: String = switch take.origin {
        case .recorded: "Recorded"
        case .importedHuman: "Imported recording"
        case .aiImported: "Imported AI audio"
        case .unknownImport: "Imported audio"
        }
        let date = RelativeDateTimeFormatter().localizedString(for: take.recordedAt, relativeTo: model.repository.clock.now)
        let peak = take.metrics.map { String(format: "%.1f dBFS", $0.peakDBFS) }
        return [origin, date, peak].compactMap { $0 }.joined(separator: " · ")
    }
}
