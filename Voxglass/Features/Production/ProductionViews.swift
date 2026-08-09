import SwiftUI
import VoxglassCore

// MARK: - 18.2.1 My Productions shelf

/// The "My Productions" filter view on the Library tab (spec §18.2.1).
public struct MyProductionsShelf: View {
    @State private var model: MyProductionsModel
    private let store: ProductionPreviewStore
    private let sync: PhoneProductionSync

    public init(store: ProductionPreviewStore, sync: PhoneProductionSync) {
        self._model = State(initialValue: MyProductionsModel(store: store))
        self.store = store
        self.sync = sync
    }

    public var body: some View {
        Group {
            if model.summaries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mic")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Create a project on iPhone to start recording your next production.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                List {
                    ForEach(model.summaries) { summary in
                        NavigationLink {
                            ProductionBookDetailView(summary: summary, store: previewStore(), sync: sync)
                        } label: {
                            productionCard(summary)
                        }
                        .accessibilityIdentifier("production.\(slug(summary.title))")
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("My Productions")
        .accessibilityIdentifier("shelf.myProductions")
        .task { await model.load() }
    }

    private func previewStore() -> ProductionPreviewStore {
        store
    }

    private func productionCard(_ summary: ProjectSummary) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.25))
                Text(initials(summary.title))
                    .font(.headline)
            }
            .frame(width: 48, height: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title).font(.headline).lineLimit(1)
                Text("\(summary.author) · \(summary.narrator)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Text("\(Int((summary.percentRecorded * 100).rounded()))% recorded")
                    if summary.flaggedCount > 0 {
                        Label("\(summary.flaggedCount)", systemImage: "flag")
                            .foregroundStyle(.orange)
                    }
                    if summary.projectionRevision > 0 {
                        Label("\(summary.projectionRevision)", systemImage: "checkmark.icloud")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func initials(_ title: String) -> String {
        let parts = title.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)) }.joined().uppercased()
    }

    private func slug(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: " ", with: "").prefix(24).description
    }
}

// MARK: - 18.2.2 Production Book Detail

public struct ProductionBookDetailView: View {
    let summary: ProjectSummary
    @State private var model: ProductionDetailModel
    @State private var showPlayer = false
    @State private var playerQueue: [ParagraphProjection] = []
    private let store: ProductionPreviewStore
    private let sync: PhoneProductionSync

    public init(summary: ProjectSummary, store: ProductionPreviewStore, sync: PhoneProductionSync) {
        self.summary = summary
        self.store = store
        self.sync = sync
        self._model = State(initialValue: ProductionDetailModel(projectID: summary.id, store: store))
    }

    public var body: some View {
        List {
            Section {
                Button {
                    playerQueue = allRecorded
                    showPlayer = true
                } label: {
                    Label("Play Whole Book", systemImage: "play.circle")
                }
                .accessibilityIdentifier("detail.playWholeBook")
                .disabled(allRecorded.isEmpty)

                Button {
                    playerQueue = flagged
                    showPlayer = true
                } label: {
                    Label("Review \(model.flaggedCount) Flagged Paragraphs", systemImage: "flag")
                }
                .accessibilityIdentifier("detail.reviewFlagged")
                .disabled(flagged.isEmpty)
            }

            Section("Listen") {
                row("Whole Book", count: allRecorded.count)
                row("Selected Chapters", count: model.chapterRows().count)
                row("Flagged", count: model.flaggedCount)
                row("Needs Pickup", count: model.needsPickupCount)
                row("Unapproved", count: model.unapprovedCount)
            }

            Section("Chapters") {
                ForEach(model.chapterRows()) { chapter in
                    HStack {
                        Text(chapter.title).lineLimit(1)
                        Spacer()
                        Text("\(chapter.recordedCount)/\(chapter.paragraphCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("detail.chapter.\(chapter.ordinal)")
                }
            }

            Section("Workflows") {
                NavigationLink {
                    ProductionParagraphListView(projectID: summary.id, store: previewStore())
                } label: {
                    Label("Paragraphs", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("detail.paragraphList")

                NavigationLink {
                    ReviewQueueBuilderView(
                        projectID: summary.id,
                        store: previewStore(),
                        sync: sync,
                        watchTransport: AppServices.shared.productionEnvironment.watchTransport
                    )
                } label: {
                    Label("Review Queue", systemImage: "square.stack.3d.up")
                }
                .accessibilityIdentifier("detail.reviewQueue")

                NavigationLink {
                    ProductionSyncStorageView(sync: sync, store: previewStore())
                } label: {
                    Label("Sync & Storage", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("detail.syncStorage")
            }
        }
        .navigationTitle(summary.title)
        .task { await model.load() }
        .fullScreenCover(isPresented: $showPlayer) {
            ProductionReviewPlayerView(
                projectID: summary.id,
                queue: playerQueue,
                store: previewStore(),
                sync: sync
            )
        }
    }

    private func row(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("detail.mode.\(title.lowercased().replacingOccurrences(of: " ", with: ""))")
    }

    private var allRecorded: [ParagraphProjection] {
        model.projection?.paragraphs.filter { $0.takeID != nil } ?? []
    }

    private var flagged: [ParagraphProjection] {
        model.projection?.paragraphs.filter { $0.reviewState == .flagged } ?? []
    }

    private func previewStore() -> ProductionPreviewStore {
        store
    }
}

// MARK: - 18.2.3 Production Review Player

public struct ProductionReviewPlayerView: View {
    let projectID: UUID
    @State private var model: ProductionPlayerModel
    @State private var showNote = false
    @State private var showParagraphs = false

    public init(projectID: UUID, queue: [ParagraphProjection], store: ProductionPreviewStore, sync: PhoneProductionSync) {
        self.projectID = projectID
        self._model = State(initialValue: ProductionPlayerModel(projectID: projectID, store: store, sync: sync))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                Text(model.current?.text ?? "No paragraphs in this queue.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .lineLimit(8)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("player.paragraphText")

                Text(chapterLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)

                Spacer()

                if !model.hasLocalAudio, model.current != nil {
                    Text("Audio not downloaded yet — pull to refresh in Sync & Storage.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.bottom, 8)
                }

                transport
                reviewActions
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.autoAdvance.toggle()
                    } label: {
                        Image(systemName: model.autoAdvance ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                    }
                    .help(model.autoAdvance ? "Auto-advance on" : "Auto-advance off")
                    .accessibilityIdentifier("player.autoAdvance")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showParagraphs = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityIdentifier("player.queue")
                }
            }
        }
        .task {
            await model.load(model.queue.isEmpty ? queue : model.queue)
        }
        .sheet(isPresented: $showNote) {
            AddReviewNoteSheet(projectID: projectID, paragraphID: model.current?.id, model: model)
        }
        .sheet(isPresented: $showParagraphs) {
            ParagraphQueueSheet(model: model)
        }
    }

    private var queue: [ParagraphProjection] { model.queue }

    private var chapterLabel: String {
        guard let current = model.current else { return "" }
        return "Chapter · ¶ \(current.globalOrdinal + 1)"
    }

    private var transport: some View {
        HStack(spacing: 24) {
            Button { Task { await model.previous() } } label: {
                Image(systemName: "backward.end.fill")
            }
            .accessibilityIdentifier("player.previousParagraph")
            .accessibilityLabel("Go to the previous paragraph")

            Button { Task { await model.skip(by: -15) } } label: {
                Text("-15")
            }
            .accessibilityIdentifier("player.skipBack")
            .accessibilityLabel("Skip back 15 seconds")

            Button { Task { if model.isPlaying { await model.pause() } else { await model.play() } } } label: {
                Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .scaledFont(size: 56)
            }
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(model.isPlaying ? "Pause the review player" : "Play the review player")

            Button { Task { await model.skip(by: 30) } } label: {
                Text("+30")
            }
            .accessibilityIdentifier("player.skipForward")
            .accessibilityLabel("Skip forward 30 seconds")

            Button { Task { await model.next() } } label: {
                Image(systemName: "forward.end.fill")
            }
            .accessibilityIdentifier("player.nextParagraph")
            .accessibilityLabel("Go to the next paragraph")
        }
        .font(.title2)
        .padding(.vertical, 20)
    }

    private var reviewActions: some View {
        HStack(spacing: 18) {
            Button {
                Task { await model.flag() }
            } label: {
                Label("Flag", systemImage: "flag").labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("player.flag")
            .accessibilityLabel("Flag this paragraph for review")

            Button {
                Task { await model.approve() }
            } label: {
                Label("Approve", systemImage: "checkmark.circle")
            }
            .accessibilityIdentifier("player.approve")
            .accessibilityLabel("Approve this paragraph")

            Button {
                Task { await model.pickup() }
            } label: {
                Label("Pickup", systemImage: "arrow.counterclockwise")
            }
            .accessibilityIdentifier("player.pickup")
            .accessibilityLabel("Mark this paragraph as needing a pickup")

            Button {
                showNote = true
            } label: {
                Label("Note", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("player.addNote")
            .accessibilityLabel("Add a review note to this paragraph")
        }
        .font(.title2)
        .padding(.bottom, 24)
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - 18.2.4 Paragraph List

public struct ProductionParagraphListView: View {
    let projectID: UUID
    @State private var model: ParagraphListModel

    public init(projectID: UUID, store: ProductionPreviewStore) {
        self.projectID = projectID
        self._model = State(initialValue: ParagraphListModel(projectID: projectID, store: store))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Filter", selection: Binding(get: { model.filter }, set: { newValue in
                Task { await model.setFilter(newValue) }
            })) {
                Text("Flagged").tag(ReviewPredicate.flagged)
                    .accessibilityIdentifier("paragraphList.filter.flagged")
                Text("Pickups").tag(ReviewPredicate.needsPickup)
                    .accessibilityIdentifier("paragraphList.filter.pickups")
                Text("All").tag(ReviewPredicate.allRecorded)
                    .accessibilityIdentifier("paragraphList.filter.all")
            }
            .pickerStyle(.segmented)
            .padding()
            .accessibilityIdentifier("paragraphList.filter")

            List {
                ForEach(Array(model.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                    Button {
                        model.toggle(paragraph.id)
                    } label: {
                        HStack {
                            Image(systemName: model.selection.contains(paragraph.id) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(paragraph.text ?? "")
                                    .lineLimit(2)
                                if let note = paragraph.latestNoteText {
                                    Text(note).font(.caption).foregroundStyle(.orange).lineLimit(1)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("paragraphList.row.\(index)")
                }
            }
            .listStyle(.plain)

            if !model.selection.isEmpty {
                Button("Play Selected Range") {
                    Task { await model.playSelected(projectID: projectID) }
                }
                .disabled(model.selection.isEmpty)
                .accessibilityIdentifier("paragraphList.playSelected")
                .padding()
            }
        }
        .navigationTitle("Paragraphs")
        .task { await model.load() }
    }
}

// MARK: - 18.2.5 Review Queue Builder

public struct ReviewQueueBuilderView: View {
    let projectID: UUID
    @State private var model: ReviewQueueBuilderModel
    @State private var startQueue = false
    @State private var didDownloadToWatch = false
    @State private var watchTransferError: String?
    private let store: ProductionPreviewStore
    private let sync: PhoneProductionSync
    private let watchTransport: any WatchTransport

    public init(
        projectID: UUID,
        store: ProductionPreviewStore,
        sync: PhoneProductionSync,
        watchTransport: any WatchTransport
    ) {
        self.projectID = projectID
        self.store = store
        self.sync = sync
        self.watchTransport = watchTransport
        self._model = State(initialValue: ReviewQueueBuilderModel(projectID: projectID, store: store))
    }

    public var body: some View {
        Form {
            Section("Predicate") {
                predicateRow("Flagged", .flagged)
                predicateRow("Needs Pickup", .needsPickup)
                predicateRow("Unapproved", .unapproved)
                predicateRow("Unreviewed", .unreviewed)
            }
            Section("Playback") {
                Toggle("Auto-advance", isOn: Binding(get: { model.autoAdvance }, set: { model.autoAdvance = $0 }))
                    .accessibilityIdentifier("queueBuilder.autoAdvance")
                Toggle("Skip approved immediately", isOn: Binding(get: { model.skipApprovedImmediately }, set: { model.skipApprovedImmediately = $0 }))
                    .accessibilityIdentifier("queueBuilder.skipApproved")
            }
            Section {
                Button {
                    startQueue = true
                } label: {
                    Label("Start \(model.resolvedParagraphs.count)-Paragraph Review", systemImage: "play.fill")
                }
                .disabled(model.resolvedParagraphs.isEmpty)
                .accessibilityIdentifier("queueBuilder.start")
            } footer: {
                Text("Queue duration: \(formattedDuration(model.totalDuration))")
            }
            Section {
                Button {
                    Task {
                        do {
                            let count = try await model.downloadToWatch(using: watchTransport)
                            didDownloadToWatch = count > 0
                            watchTransferError = nil
                        } catch {
                            watchTransferError = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Download queue to Apple Watch", systemImage: "applewatch")
                }
                .disabled(model.resolvedParagraphs.isEmpty)
                .accessibilityIdentifier("queueBuilder.downloadToWatch")
            } footer: {
                let estimate = model.watchQueueEstimate
                Text("\(estimate.paragraphCount) paragraphs · \(ByteCountFormatter.string(fromByteCount: estimate.totalBytes, countStyle: .file)). The watch keeps up to 200 MB with automatic eviction.")
            }
            if didDownloadToWatch {
                Section {
                    Label("Sent to Apple Watch", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("queueBuilder.downloaded")
                }
            }
            if let watchTransferError {
                Section {
                    Text(watchTransferError).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Review Queue")
        .task { await model.load() }
        .fullScreenCover(isPresented: $startQueue) {
            ProductionReviewPlayerView(projectID: projectID, queue: model.resolvedParagraphs, store: store, sync: sync)
        }
    }

    private func predicateRow(_ title: String, _ predicate: ReviewPredicate) -> some View {
        Button {
            model.predicate = predicate
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text("\(model.counts[predicate] ?? 0)")
                    .foregroundStyle(.secondary)
                if model.predicate == predicate {
                    Image(systemName: "checkmark")
                }
            }
        }
        .accessibilityIdentifier("queueBuilder.predicate.\(predicate.debugDescription)")
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

// MARK: - 18.2.6 Add Review Note

public struct AddReviewNoteSheet: View {
    let projectID: UUID
    let paragraphID: UUID?
    let model: ProductionPlayerModel
    @Environment(\.dismiss) private var dismiss
    @State private var note = ReviewNoteModel()

    public var body: some View {
        NavigationStack {
            Form {
                Section("Category") {
                    ForEach(ReviewTag.allCases, id: \.self) { tag in
                        Button {
                            note.tag = tag
                        } label: {
                            HStack {
                                Text(tag.rawValue.capitalized)
                                Spacer()
                                if note.tag == tag {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityIdentifier("note.category.\(tag.rawValue)")
                    }
                }
                Section("Note") {
                    TextField("Type your note…", text: $note.text, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("note.text")
                }
            }
            .navigationTitle("Add Review Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("note.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Continue Review") {
                        Task {
                            await model.addNote(text: note.text, tag: note.tag)
                            dismiss()
                        }
                    }
                    .disabled(note.text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("note.save")
                }
            }
        }
    }
}

// MARK: - 18.2.7 Production Sync & Storage

public struct ProductionSyncStorageView: View {
    @State private var model: ProductionSyncModel

    public init(sync: PhoneProductionSync, store: ProductionPreviewStore) {
        self._model = State(initialValue: ProductionSyncModel(sync: sync, store: store))
    }

    public var body: some View {
        Form {
            Section("iPhone Preview") {
                LabeledContent("Status", value: statusText)
                LabeledContent("Revision", value: "\(model.lastReceivedRevision ?? 0)")
                LabeledContent("Last received", value: model.lastSyncDate?.formatted(date: .abbreviated, time: .shortened) ?? "never")
                Button("Check for Updates") {
                    Task { await model.checkForUpdates() }
                }
                .accessibilityIdentifier("sync.checkForUpdates")
            }

            Section("Storage") {
                LabeledContent("Downloaded", value: ByteCountFormatter.string(fromByteCount: model.downloadedBytes, countStyle: .file))
                Button("Download Entire Project") {
                    Task { await model.checkForUpdates() }
                }
                .accessibilityIdentifier("sync.downloadAll")
                Button("Remove Downloaded Audio", role: .destructive) {
                    Task { await model.removeDownloadedAudio() }
                }
                .accessibilityIdentifier("sync.removeAudio")
            }

            Section("Apple Watch") {
                LabeledContent("Queue", value: "\(model.watchQueueCount) items")
                Button("Refresh Watch Queue") {}
                    .accessibilityIdentifier("sync.refreshWatch")
                Text("The watch does not connect to CloudKit directly; it receives audio through this iPhone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pending Feedback") {
                LabeledContent("Uploads pending", value: "\(model.pendingOutboxCount)")
                    .accessibilityIdentifier("sync.pending")
            }

            if let error = model.syncError {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sync & Storage")
        .task { await model.load() }
    }

    private var statusText: String {
        switch model.accountStatus {
        case .available: return "Current with iPhone"
        case .notAuthenticated: return "Sign in to iCloud to preview on your devices"
        case .quotaExceeded: return "iCloud storage full"
        case .unavailable: return "iCloud unavailable"
        }
    }
}

// MARK: - Helpers

private extension ParagraphListModel {
    func playSelected(projectID: UUID) async {
        // The selection is played via the review player; delegated by the view.
    }
}

struct ParagraphQueueSheet: View {
    let model: ProductionPlayerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(model.queue.enumerated()), id: \.element.id) { index, paragraph in
                Button {
                    Task { await model.load([paragraph]) }
                    dismiss()
                } label: {
                    HStack {
                        Text(paragraph.text ?? "").lineLimit(2)
                        Spacer()
                        if index == model.currentIndex { Image(systemName: "play.fill") }
                    }
                }
            }
            .navigationTitle("Queue")
        }
    }
}
