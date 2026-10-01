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
                        .voxFont(.callout, weight: .medium)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("paragraphReview.text")

                    if paragraph.isDrifted { driftBanner }
                    transport(paragraph)
                    takesCard
                    actions(paragraph)
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
            Text(context.map { String(localized: "Chapter \($0.chapterOrdinal + 1) · ¶ \($0.number) of \($0.count)") } ?? String(localized: "Paragraph review"))
                .voxFont(.callout, weight: .heavy)
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
        .raisedSurface()
    }

    private var driftBanner: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("The text changed after this was recorded", systemImage: "exclamationmark.triangle.fill")
                .voxFont(.footnote, weight: .semibold)
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
                Label(model.hydratingParagraphID == currentID ? "Downloading…" : "Download \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))", systemImage: "icloud.and.arrow.down") // l10n-exempt: state-dependent accessibility or status copy
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
                    Label(isCurrentPlaying ? "Pause" : "Play take", systemImage: isCurrentPlaying ? "pause.fill" : "play.fill") // l10n-exempt: state-dependent accessibility or status copy
                        .voxFont(.subheadline, weight: .bold)
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
                    .voxFont(.caption2, design: .monospaced) // mono-exempt: paragraph index
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
                Text("TAKES").voxFont(.caption, weight: .bold).foregroundStyle(Palette.ink3)
                Spacer()
                if takes.count >= 2 {
                    Button("Compare") { showCompare = true }
                        .voxFont(.caption, weight: .bold)
                        .accessibilityIdentifier("paragraphReview.compare")
                }
            }
            if takes.isEmpty {
                Text("No take yet").voxFont(.footnote).foregroundStyle(Palette.ink3)
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
                                .voxFont(.footnote, weight: .semibold).foregroundStyle(Palette.ink)
                            Text(takeSubtitle(take))
                                .voxFont(.caption2).foregroundStyle(Palette.ink3)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(NarrationPressStyle())
                .accessibilityIdentifier("paragraphReview.take.\(index)")
            }
        }
        .padding(14)
        .raisedSurface()
    }

    /// One action per row: three targets crammed into a single `HStack` were
    /// too small to hit reliably, and Approve gave no sign it had landed
    /// (field report 2026-08-19, items 1 and 2).
    private func actions(_ paragraph: FlowParagraph) -> some View {
        let isApproved = paragraph.state == .approved
        return VStack(spacing: 10) {
            Button {
                model.toggleApproval(for: currentID)
                Task { await model.persist() }
            } label: {
                Label(isApproved ? "Approved" : "Approve", // l10n-exempt: state-dependent accessibility or status copy
                      systemImage: isApproved ? "checkmark.circle.fill" : "checkmark.circle")
                    .voxFont(.subheadline, weight: .bold)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(isApproved ? Palette.ok : Palette.brass)
            .accessibilityIdentifier("paragraphReview.approve")

            Button {
                showFlagSheet = true
            } label: {
                Label("Flag", systemImage: "flag")
                    .voxFont(.subheadline, weight: .bold)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("paragraphReview.flag")

            Button {
                openRecorder()
            } label: {
                Label("Re-record", systemImage: "mic")
                    .voxFont(.subheadline, weight: .bold)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("paragraphReview.rerecord")

            Button {
                showImport = true
            } label: {
                Label("Import audio", systemImage: "square.and.arrow.down")
                    .voxFont(.subheadline, weight: .bold)
                    .frame(maxWidth: .infinity, minHeight: 48)
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
        .voxFont(.footnote, weight: .bold)
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
        Text(text).voxFont(.caption2, weight: .bold)
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func roleName(_ role: ParagraphRole?) -> String {
        switch role {
        case .libriVoxIntro: String(localized: "Intro")
        case .libriVoxOutro: String(localized: "Outro")
        case .chapterHeading: String(localized: "Chapter heading")
        case .retailOpeningCredits: String(localized: "Opening credits")
        case .retailClosingCredits: String(localized: "Closing credits")
        case .body, .none: String(localized: "Body")
        }
    }

    private func stateName(_ state: FlowParagraphState) -> String {
        switch state {
        case .notRecorded: String(localized: "Not recorded")
        case .recorded: String(localized: "Recorded")
        case .approved: String(localized: "Approved")
        case .flagged: String(localized: "Flagged")
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
        case .recorded: String(localized: "Recorded")
        case .importedHuman: String(localized: "Imported recording")
        case .aiImported: String(localized: "Imported AI audio")
        case .unknownImport: String(localized: "Imported audio")
        }
        let date = RelativeDateTimeFormatter().localizedString(for: take.recordedAt, relativeTo: model.repository.clock.now)
        let peak = take.metrics.map { String(format: "%.1f dBFS", $0.peakDBFS) }
        return [origin, date, peak, perceivedVolumeLabel(take)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The estimated perceived volume this take will export at, against the
    /// destination's band, so the outlier paragraph is findable without opening
    /// the validation report (field report 2026-08-19, item 13).
    private func perceivedVolumeLabel(_ take: Take) -> String? {
        guard let metrics = take.metrics,
              let destination = model.project?.profile.intendedDestination,
              case .replayGainBand(let low, let high, let target) = DestinationProfile.profile(for: destination).loudness
        else { return nil }
        let perceived = target - metrics.replayGainDB
        guard perceived.isFinite else { return nil }
        let value = "\(Int(perceived.rounded())) dB"
        if perceived < low { return "\(value) · quiet" }
        if perceived > high { return "\(value) · loud" }
        return value
    }
}
