import SwiftUI
import VoxglassCore

/// The project dashboard (mockup 04), pushed when a project in My Narrations is
/// tapped. Leads with one action — "Record next" (§15.5) — then progress, then
/// review counts, then the storage card, then chapters. For a long work the
/// storage card is prominent because that is where offload matters (§8.3).
struct ProjectDashboardView: View {
    @Environment(DiscoveryEnvironment.self) private var discovery
    @State private var dashboard: ProjectDashboard
    @State private var flowProject: AudiobookProject?
    @State private var showScriptEditor = false
    @State private var showStorage = false
    @State private var model: NarrationFlowModel
    @State private var showValidationReport = false
    @State private var narratorBackfill = ""
    @State private var sourceURLBackfill = ""
    let project: AudiobookProject

    init(project: AudiobookProject) {
        self.project = project
        _dashboard = State(initialValue: ProjectDashboard(project: project))
        _model = State(initialValue: NarrationFlowModel(existing: project))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                recordNextButton

                progressCard

                detailsCard

                NarrationSecondaryButton(title: "Check my recording", systemImage: "checkmark.circle", isBusy: model.isValidating, identifier: "dashboard.checkRecording") {
                    Task {
                        model.validationDestination = model.project?.profile.intendedDestination ?? .personalMaster
                        await model.runValidation()
                        showValidationReport = true
                    }
                }

                needsAttentionCard

                storageCard

                SectionTitle(title: "Work on", actionTitle: nil)
                workOnCard

                SectionTitle(title: "Chapters", actionTitle: nil)
                chaptersCard
            }
            .padding(18)
        }
        .background(VoxglassBackground())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(project.metadata.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $flowProject) { project in
            NarrationFlowRoot(existing: project, startAt: dashboard.recordNext == nil ? .reviewList : nil)
        }
        .navigationDestination(isPresented: $showScriptEditor) {
            ScriptEditorView(project: project)
        }
        .navigationDestination(isPresented: $showStorage) {
            StorageSettingsView()
        }
        .task {
            await model.load(project)
            narratorBackfill = model.narrator
            sourceURLBackfill = model.sourceURLText
            await discovery.reloadNarrations()
        }
        .sheet(isPresented: $showValidationReport) { ValidationReportSheet(model: model) }
        .alert("Add narrator name", isPresented: $model.needsNarratorPrompt) {
            TextField("Narrator name", text: $narratorBackfill)
            Button("Save") { model.saveNarratorName(narratorBackfill) }
            Button("Not now", role: .cancel) {}
        } message: { Text("Add the narrator name used in this recording.") }
        .alert("Add source URL", isPresented: $model.needsSourceURLPrompt) {
            TextField("https://…", text: $sourceURLBackfill)
            Button("Save") { model.saveSourceURL(sourceURLBackfill) }
            Button("Not now", role: .cancel) {}
        } message: { Text("Add the source page or edition used for this narration.") }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [NarrationPalette.forestDeep, NarrationPalette.forest], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(initials)
                    .scaledFont(size: 30, weight: .heavy)
                    .foregroundStyle(NarrationPalette.creamWarm)
            }
            .frame(width: 120, height: 160)

            Text(project.metadata.title)
                .scaledFont(size: 21, weight: .heavy)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
            Text("\(project.metadata.author) · narrated by \(project.metadata.narrator.isEmpty ? "you" : project.metadata.narrator)")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.ink2)
                .padding(.top, 3)

            HStack(spacing: 6) {
                chip(project.profile.intendedDestination.label, tint: Palette.brass)
                if dashboard.flaggedCount > 0 {
                    chip("\(dashboard.flaggedCount) flagged", tint: NarrationPalette.brassSoft)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Record next

    private var recordNextButton: some View {
        NarrationPrimaryButton(title: recordNextCaption, identifier: "dashboard.recordNext") {
            flowProject = project
        }
    }

    private var recordNextCaption: String {
        guard let next = dashboard.recordNext else {
            return "Everything recorded — review"
        }
        return "Record next — ¶ \(next.paragraphNumber), Chapter \(next.chapterOrdinal + 1)"
    }

    // MARK: - Progress

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Progress").scaledFont(size: 16, weight: .bold).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(Int(dashboard.percentRecorded * 100))%").scaledFont(size: 14, weight: .bold, design: .monospaced).foregroundStyle(Palette.ink)
            }
            progressBar(value: dashboard.percentRecorded)
            kv("Recorded", "\(dashboard.recordedCount) of \(dashboard.paragraphCount) ¶")
            kv("Approved", "\(dashboard.approvedCount) ¶")
            kv("Chapters complete", "\(dashboard.chaptersComplete) of \(dashboard.chapterCount)")
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
        .accessibilityIdentifier("dashboard.progress")
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details").scaledFont(size: 16, weight: .bold).foregroundStyle(Palette.ink)
            detailField("Title", field: .title, value: model.project?.metadata.title ?? "")
            detailField("Author", field: .author, value: model.project?.metadata.author ?? "")
            detailField("Narrator", field: .narrator, value: model.project?.metadata.narrator ?? "")
            detailField("Language", field: .language, value: model.project?.metadata.language ?? "")
            detailField("Source URL", field: .sourceURL, value: model.project?.rights.sourceURL?.absoluteString ?? "")
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private func detailField(_ label: String, field: MetadataField, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).scaledFont(size: 10.5, weight: .bold).foregroundStyle(Palette.ink3)
            TextField(label, text: Binding(
                get: {
                    switch field {
                    case .title: model.project?.metadata.title ?? ""
                    case .author: model.project?.metadata.author ?? ""
                    case .narrator: model.project?.metadata.narrator ?? ""
                    case .language: model.project?.metadata.language ?? ""
                    case .sourceURL: model.project?.rights.sourceURL?.absoluteString ?? ""
                    default: value
                    }
                },
                set: { model.saveMetadataField(field, value: $0) }
            ))
            .textInputAutocapitalization(field == .sourceURL ? .never : .sentences)
            .accessibilityIdentifier("dashboard.details.\(field.rawValue)")
        }
    }

    private func progressBar(value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Palette.brass, Palette.brass.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * value)
            }
        }
        .frame(height: 8)
    }

    // MARK: - Needs attention

    private var needsAttentionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Needs your attention").scaledFont(size: 16, weight: .bold).foregroundStyle(Palette.ink)
                Spacer()
                attentionChip("\(dashboard.flaggedCount + dashboard.needsPickupCount + dashboard.driftCount)")
            }
            .padding(.bottom, 4)

            attentionRow("Flagged", "\(dashboard.flaggedCount) ¶", systemImage: "flag.fill", tint: NarrationPalette.brassSoft, id: "dashboard.flagged")
            VoxglassListDivider()
            attentionRow("Needs pickup", "\(dashboard.needsPickupCount) ¶ · blocks export", systemImage: "arrow.clockwise", tint: NarrationPalette.brassSoft, id: "dashboard.pickups")
            VoxglassListDivider()
            attentionRow("Text changed after recording", "\(dashboard.driftCount) ¶", systemImage: "pencil", tint: NarrationPalette.brassSoft, id: "dashboard.drift")

            NarrationSecondaryButton(title: "Start review queue", identifier: "dashboard.startReviewQueue") {
                flowProject = project
            }
            .padding(.top, 11)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private func attentionRow(_ title: String, _ detail: String, systemImage: String, tint: Color, id: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).scaledFont(size: 15).foregroundStyle(tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(size: 14, weight: .semibold).foregroundStyle(Palette.ink)
                Text(detail).scaledFont(size: 12).foregroundStyle(Palette.ink3)
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(size: 12).foregroundStyle(Palette.ink3)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { flowProject = project }
        .accessibilityIdentifier(id)
    }

    private func attentionChip(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .bold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(NarrationPalette.brassSoft)
            .background(NarrationPalette.brassSoft.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(NarrationPalette.brassSoft.opacity(0.4), lineWidth: 1))
    }

    // MARK: - Storage

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storage & iCloud").scaledFont(size: 16, weight: .bold).foregroundStyle(Palette.ink)
                Spacer()
                chip("Backed up", tint: Palette.ok)
            }
            Text("\(onDeviceBytes) on iPhone · chapters verified in iCloud can be offloaded. Local-only takes are never removed.")
                .scaledFont(size: 12)
                .foregroundStyle(Palette.ink2)
            Button {
                showStorage = true
            } label: {
                Text("Manage storage")
                    .scaledFont(size: 13, weight: .bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Palette.brass.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.brass.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(Palette.brass)
            }
            .buttonStyle(.plain)
            .tactileTap()
            .padding(.top, 4)
            .accessibilityIdentifier("dashboard.manageStorage")
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
        .accessibilityIdentifier("dashboard.storage")
    }

    private var onDeviceBytes: String {
        let bytes = project.allParagraphs.reduce(Int64(0)) { total, paragraph in
            total + paragraph.takes.reduce(Int64(0)) { partial, take in
                partial + Int64(take.assetRef.byteCount)
            }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Work on

    private var workOnCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            workOnRow("Script", "Split, merge, edit, pronunciation notes", systemImage: "text.alignleft", id: "dashboard.script") {
                showScriptEditor = true
            }
            VoxglassListDivider()
            workOnRow("Assembly", "Gaps, room tone, chapter renders", systemImage: "waveform.path", id: "dashboard.assemble") {
                flowProject = project
            }
            VoxglassListDivider()
            workOnRow("Metadata & rights", project.rights.isAttested ? "Attested" : "Artwork missing", systemImage: "info.circle", id: "dashboard.metadata") {
                flowProject = project
            }
            VoxglassListDivider()
            workOnRow("Validate & export", "Check issues before export", systemImage: "checkmark.circle", id: "dashboard.validate") {
                flowProject = project
            }
        }
        .padding(6)
        .glassSurface(cornerRadius: 16)
    }

    private func workOnRow(_ title: String, _ detail: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).scaledFont(size: 15).foregroundStyle(Palette.brass).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(size: 14, weight: .semibold).foregroundStyle(Palette.ink)
                    Text(detail).scaledFont(size: 12).foregroundStyle(Palette.ink3)
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(size: 12).foregroundStyle(Palette.ink3)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: - Chapters

    private var chaptersCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(dashboard.chapters.prefix(8)) { chapter in
                chapterRow(chapter)
                if chapter.id != dashboard.chapters.prefix(8).last?.id {
                    VoxglassListDivider()
                }
            }
        }
        .padding(6)
        .glassSurface(cornerRadius: 16)
    }

    private func chapterRow(_ chapter: ChapterProgress) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(chapter.ordinal + 1). \(chapter.title)")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(chapter.paragraphCount) ¶")
                    .scaledFont(size: 12)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer()
            chapterChip(chapter)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("dashboard.chapter.\(chapter.ordinal)")
    }

    @ViewBuilder
    private func chapterChip(_ chapter: ChapterProgress) -> some View {
        if chapter.isComplete {
            chip("Complete", tint: Palette.ok)
        } else if chapter.isNotStarted {
            chip("Not started", tint: Palette.ink3)
        } else {
            chip("\(Int(chapter.percentRecorded * 100))%", tint: Palette.brass)
        }
    }

    // MARK: - Helpers

    private var initials: String {
        project.metadata.title.split(separator: " ").prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .bold)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
    }

    private func kv(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).scaledFont(size: 13).foregroundStyle(Palette.ink3)
            Spacer()
            Text(value).scaledFont(size: 13).foregroundStyle(Palette.ink)
        }
    }
}

// MARK: - Storage sheet

private extension DestinationID {
    var label: String {
        switch self {
        case .librivox: return "LibriVox lane"
        case .internetArchive: return "Internet Archive lane"
        case .personalMaster: return "Personal master"
        case .acx, .appleBooksAggregator: return "Retail"
        }
    }
}
