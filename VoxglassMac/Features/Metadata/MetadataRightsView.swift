import SwiftUI
import VoxglassCore

/// Metadata & Rights (spec §18.1.12): Book Details / Rights / Artwork /
/// Identifiers tabs, a live eligibility header, and the Narration Origin Audit.
public struct MetadataRightsView: View {
    @Bindable var model: MetadataRightsModel
    var onSaved: (AudiobookProject) -> Void = { _ in }

    public init(model: MetadataRightsModel, onSaved: @escaping (AudiobookProject) -> Void = { _ in }) {
        _model = Bindable(model)
        self.onSaved = onSaved
    }

    @State private var tab: Tab = .details

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $tab) {
                detailsTab.tabItem { Label("Book Details", systemImage: "book") }.tag(Tab.details)
                    .accessibilityIdentifier("metadata.tab.details")
                rightsTab.tabItem { Label("Rights", systemImage: "checkmark.shield") }.tag(Tab.rights)
                    .accessibilityIdentifier("metadata.tab.rights")
                artworkTab.tabItem { Label("Artwork", systemImage: "photo") }.tag(Tab.artwork)
                    .accessibilityIdentifier("metadata.tab.artwork")
                identifiersTab.tabItem { Label("Identifiers", systemImage: "number") }.tag(Tab.identifiers)
                    .accessibilityIdentifier("metadata.tab.identifiers")
            }
            .padding(16)
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private enum Tab: Hashable { case details, rights, artwork, identifiers }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Metadata & Rights", systemImage: "doc.text")
                .font(.headline)
            Spacer()
            eligibilityBadge
            Button("Save") {
                Task {
                    await model.save()
                    if model.didSave { onSaved(model.workingProject) }
                }
            }
            .accessibilityIdentifier("metadata.save")
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private var eligibilityBadge: some View {
        Group {
            if model.eligibility.librivoxEligible {
                Label("LibriVox eligible so far", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("LibriVox ineligible · \(model.eligibility.aiParagraphCount) AI paragraph\(model.eligibility.aiParagraphCount == 1 ? "" : "s")", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
        .accessibilityIdentifier("metadata.originAudit")
    }

    // MARK: - Tabs

    private var detailsTab: some View {
        Form {
            TextField("Title", text: $model.title)
                .accessibilityIdentifier("metadata.title")
            TextField("Subtitle", text: $model.subtitle)
            TextField("Author", text: $model.author)
                .accessibilityIdentifier("metadata.author")
            TextField("Narrator", text: $model.narrator)
                .accessibilityIdentifier("metadata.narrator")
            TextField("Translator", text: $model.translator)
            TextField("Language (BCP-47)", text: $model.language)
                .accessibilityIdentifier("metadata.language")
            TextField("Publisher", text: $model.publisher)
            TextField("Copyright year", text: $model.copyrightYearText)
            TextField("Production year", text: $model.productionYearText)
            TextField("Rights holder", text: $model.rightsHolder)
            TextField("ISBN", text: $model.isbn)
            TextField("ASIN", text: $model.asin)
            TextField("Subjects (comma separated)", text: $model.subjectsText)
            TextEditor(text: $model.description)
                .frame(minHeight: 90)
                .accessibilityIdentifier("metadata.description")
        }
        .formStyle(.grouped)
    }

    private var rightsTab: some View {
        Form {
            Picker("Rights basis", selection: $model.rightsBasis) {
                ForEach(RightsBasis.allCases, id: \.self) { basis in
                    Text(basis.rawValue).tag(basis)
                }
            }
            TextField("Source edition URL", text: $model.sourceURLText)
                .accessibilityIdentifier("metadata.sourceURL")
            TextField("Edition year", text: $model.editionYearText)
            TextField("Evidence notes", text: $model.evidenceNotes)
            TextField("Attested by", text: $model.attestedBy)
            Toggle("I attest this information is accurate", isOn: Binding(
                get: { model.isAttested },
                set: { model.setAttested($0) }
            ))
            Text(LegalStrings.noCopyrightDetermination)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("metadata.attest")
        }
        .formStyle(.grouped)
    }

    // MARK: - Artwork tab (§18.1.12, F-28)

    @State private var showArtworkPicker = false

    private var artworkTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let data = model.coverOriginalData, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .overlay(Text("No cover").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 160, height: 160)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Cover art")
                        .font(.headline)
                    if let cover = model.coverOriginal {
                        Text("\(cover.pixelWidth)×\(cover.pixelHeight) original")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let derivative = model.cover2400 {
                        Label("2400 px derivative ready (\(derivative.pixelWidth)×\(derivative.pixelHeight))", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityIdentifier("metadata.artwork.derivative")
                    }
                    HStack(spacing: 10) {
                        Button("Choose Cover…") {
                            showArtworkPicker = true
                        }
                        .accessibilityIdentifier("metadata.artwork")
                        if model.hasCover {
                            Button("Remove") {
                                Task { await model.removeArtwork() }
                            }
                            .accessibilityIdentifier("metadata.artwork.remove")
                        }
                    }
                    if model.isGenerating2400 {
                        ProgressView("Generating 2400 px derivative…")
                            .controlSize(.small)
                    }
                }
            }

            if !model.artworkIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.artworkIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("metadata.artworkIssues")
            }

            Text(artworkRuleCopy)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .fileImporter(isPresented: $showArtworkPicker, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                Task { await model.importArtwork(at: url) }
            }
        }
    }

    private var artworkRuleCopy: String {
        switch model.artworkRule {
        case .none: return "This destination has no artwork requirement."
        case .optionalSquare(let minPx): return "This destination accepts an optional square cover of at least \(minPx) px."
        case .requiredSquare(let minPx, _, _): return "This destination requires a square cover of at least \(minPx) px. The 2400 px derivative satisfies every destination."
        }
    }

    private var identifiersTab: some View {
        Form {
            Section {
                TextField("Internet Archive identifier", text: $model.archiveIdentifier)
                    .accessibilityIdentifier("metadata.identifier")
                HStack {
                    Text("Suggested")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(model.suggestedIdentifier)
                        .font(.caption.monospaced())
                    Button("Suggest") {
                        model.suggestIdentifier()
                    }
                    .font(.caption)
                }
                if !model.isArchiveIdentifierValid {
                    Label("Identifiers are permanent and must be unique on archive.org. Confirm availability before uploading.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Internet Archive")
            }
            Section {
                Text("Narration Origin Audit")
                    .font(.subheadline.weight(.semibold))
                Text("\(model.eligibility.humanParagraphCount) human-origin paragraphs · \(model.eligibility.aiParagraphCount) AI-origin paragraphs")
                    .font(.caption)
                Text("LibriVox does not accept machine-generated audio. AI-origin selected takes make the project ineligible for LibriVox export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
