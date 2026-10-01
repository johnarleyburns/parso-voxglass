import SwiftUI
import UniformTypeIdentifiers
import VoxglassCore
import VoxglassEncoders

/// Import existing audio sheet (mockup 07, spec §10). Storage impact is stated
/// *before* the import runs; the origin declaration is mandatory compliance
/// metadata — a non-human or unknown origin blocks LibriVox export once a take
/// from it is selected.
/// Identifiers: `importAudio.trashOriginal`, `importAudio.mode`,
/// `importAudio.mode.silence`, `importAudio.mode.sequential`,
/// `importAudio.mode.whole`, `importAudio.origin`,
/// `importAudio.origin.selfRecorded`, `importAudio.origin.humanExternal`,
/// `importAudio.origin.aiImported`, `importAudio.origin.unknown`,
/// `importAudio.start`.
struct ImportAudioView: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let selection = model.importSelection {
                        storageCard(selection)
                    } else {
                        pickPrompt
                    }

                    if model.importSelection != nil {
                        assignmentCard
                        originCard
                        importButton
                    }

                    if model.isImportingAudio {
                        HStack(spacing: 8) {
                            ProgressView().tint(Palette.brass)
                            Text("Importing…").voxFont(.caption).foregroundStyle(Palette.ink2)
                        }
                        .padding(.top, 6)
                    }
                    if let error = model.importError {
                        Text(error).voxFont(.caption).foregroundStyle(Palette.danger)
                    }
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationTitle("Import Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("importAudio.done")
                }
            }
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: ImportAudioView.audioContentTypes
        ) { result in
            switch result {
            case .success(let url):
                Task { await model.inspectAudioFile(url) }
            case .failure(let error):
                model.importSelection = nil
                model.importPlan = nil
                model.importError = (error as NSError).code == NSUserCancelledError
                    ? nil
                    : String(localized: "Couldn't access that audio file: \(error.localizedDescription)")
            }
        }
        .presentationDetents([.large])
    }

    private var pickPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note").scaledFont(size: 34) // type-exempt: import artwork icon
            Text("Choose a WAV, AIFF, CAF, M4A, MP3, or FLAC file")
                .voxFont(.subheadline)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Button {
                showPicker = true
            } label: {
                Text("Choose file ▸")
                    .voxFont(.subheadline, weight: .heavy)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 13))
                    .foregroundStyle(NarrationPalette.espresso)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("importAudio.pick")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .raisedSurface()
    }

    private func storageCard(_ selection: FlowImportedAudio) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "music.note").voxFont(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.fileName)
                        .voxFont(.subheadline, weight: .heavy)
                        .foregroundStyle(Palette.ink)
                    Text(formatCaption(selection))
                        .voxFont(.caption2)
                        .foregroundStyle(Palette.ink3)
                }
                Spacer()
                Button("Choose another") {
                    showPicker = true
                }
                .voxFont(.caption2, weight: .bold)
                .foregroundStyle(Palette.brass)
                .buttonStyle(.plain)
            }

            kv("Original size", byteString(selection.originalSize))
            kv("Estimated slices", estimatedSlicesText)
            kv("Free on iPhone after import", afterText, tint: afterTint)

            Toggle(isOn: importTrashBinding) {
                Text("Move the original to Trash after every slice is verified")
                    .voxFont(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            .tint(Palette.brass)
            .padding(.top, 4)
            .accessibilityIdentifier("importAudio.trashOriginal")
        }
        .padding(14)
        .raisedSurface()
    }

    private var assignmentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOW TO ASSIGN IT")
                .voxFont(.caption, weight: .bold)
                .foregroundStyle(Palette.ink3)

            VStack(spacing: 0) {
                assignmentRow("Split by silence, then match in order", caption: LocalizedStringKey(silenceCaption), mode: .splitBySilence, id: "importAudio.mode.silence")
                VoxglassListDivider()
                assignmentRow("Assign detected segments sequentially", caption: "You confirm each boundary", mode: .sequential, id: "importAudio.mode.sequential")
                VoxglassListDivider()
                assignmentRow("One paragraph, whole file", caption: "For a single poem or a pickup", mode: .wholeParagraph, id: "importAudio.mode.whole")
            }
            .padding(.horizontal, 13)
            .raisedSurface()
            .accessibilityIdentifier("importAudio.mode")

            if let plan = model.importPlan, !plan.slices.isEmpty, plan.mode != .wholeParagraph {
                HStack {
                    Text("Detected segments")
                        .voxFont(.footnote, weight: .bold)
                        .foregroundStyle(Palette.ink)
                    Spacer()
                    Text(plan.isFullyAssigned ? "\(plan.slices.count) matched" : "\(plan.slices.count - plan.unmatchedSliceCount) matched · \(plan.unmatchedSliceCount) extra") // l10n-exempt: state-dependent accessibility or status copy
                        .voxFont(.caption2, weight: .bold)
                        .foregroundStyle(plan.isFullyAssigned ? Palette.ok : Palette.brass)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((plan.isFullyAssigned ? Palette.ok : Palette.brass).opacity(0.12), in: Capsule())
                }
                VStack(spacing: 0) {
                    ForEach(Array(plan.slices.enumerated()).prefix(5), id: \.element.id) { index, slice in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .voxFont(.caption2, weight: .bold)
                                .foregroundStyle(Palette.ink3)
                            Text(sliceCaption(slice: slice, rate: model.importSelection?.decodedSampleRate ?? 0))
                                .voxFont(.caption2)
                                .foregroundStyle(Palette.ink2)
                            Spacer()
                            Text(slice.paragraphID != nil ? "paragraphs matched" : "extra") // l10n-exempt: state-dependent accessibility or status copy
                                .voxFont(.caption2, weight: .bold)
                                .foregroundStyle(slice.paragraphID != nil ? Palette.ok : Palette.brass)
                        }
                        .padding(.vertical, 8)
                        if index < plan.slices.count - 1 { VoxglassListDivider() }
                    }
                }
                .padding(.horizontal, 13)
                .raisedSurface()
            }
        }
    }

    private var originCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHO OR WHAT MADE THIS RECORDING?")
                .voxFont(.caption, weight: .bold)
                .foregroundStyle(Palette.ink3)

            VStack(spacing: 0) {
                originRow("I recorded it myself", origin: .selfRecorded, id: "importAudio.origin.selfRecorded")
                VoxglassListDivider()
                originRow("Another person recorded it", origin: .humanExternal, id: "importAudio.origin.humanExternal")
                VoxglassListDivider()
                originRow("AI-generated or AI-processed", caption: "Blocks LibriVox export", origin: .aiImported, id: "importAudio.origin.aiImported")
                VoxglassListDivider()
                originRow("I'm not sure", caption: "Blocks LibriVox export", origin: .unknown, id: "importAudio.origin.unknown")
            }
            .padding(.horizontal, 13)
            .raisedSurface()
            .accessibilityIdentifier("importAudio.origin")

            Text(LegalStrings.librivoxHumanOnly)
                .voxFont(.caption2)
                .foregroundStyle(Palette.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importButton: some View {
        Button {
            Task { await model.runAudioImport() }
        } label: {
            Text("Import \(importActionLabel)")
                .voxFont(.subheadline, weight: .heavy)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(NarrationPalette.espresso)
        }
        .buttonStyle(.plain)
        .tactileTap()
        .disabled(model.importPlan == nil || model.importSelection == nil)
        .accessibilityIdentifier("importAudio.start")
    }

    private func assignmentRow(_ title: LocalizedStringKey, caption: LocalizedStringKey, mode: AudioImportMode, id: String) -> some View {
        Button {
            model.importMode = mode
            rebuild()
        } label: {
            HStack(spacing: 10) {
                radio(on: model.importMode == mode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).voxFont(.footnote, weight: .semibold).foregroundStyle(Palette.ink)
                    Text(caption).voxFont(.caption2).foregroundStyle(Palette.ink3)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func originRow(_ title: LocalizedStringKey, caption: LocalizedStringKey? = nil, origin: FlowImportOrigin, id: String) -> some View {
        Button {
            model.importOrigin = origin
        } label: {
            HStack(spacing: 10) {
                radio(on: model.importOrigin == origin)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).voxFont(.footnote, weight: .semibold).foregroundStyle(Palette.ink)
                    if let caption {
                        Text(caption).voxFont(.caption2).foregroundStyle(Palette.brass)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func radio(on: Bool) -> some View {
        ZStack {
            Circle().stroke(on ? Palette.brass : Palette.ink3, lineWidth: 1.5).frame(width: 18, height: 18)
            if on {
                Circle().fill(Palette.brass).frame(width: 9, height: 9)
            }
        }
    }

    private func rebuild() {
        guard let selection = model.importSelection else { return }
        Task {
            let decoder = RoutingAudioDecoder()
            if let decoded = try? await decoder.decodeToMonoFloat(selection.sourceURL, targetSampleRate: nil) {
                model.rebuildImportPlan(samples: decoded.samples, sampleRate: decoded.sampleRate)
            }
        }
    }

    private var importTrashBinding: Binding<Bool> {
        Binding(
            get: { model.importTrashOriginal },
            set: { model.importTrashOriginal = $0 }
        )
    }

    private var silenceCaption: String {
        guard let plan = model.importPlan else { return String(localized: "Detecting segments…") }
        return plan.isFullyAssigned
            ? String(localized: "\(plan.slices.count) segments · matched in order")
            : String(localized: "\(plan.slices.count) segments")
    }

    private var estimatedSlicesText: String {
        guard let plan = model.importPlan else { return "—" }
        if plan.mode == .wholeParagraph { return "1 file" }
        return "\(plan.slices.count) files"
    }

    private var afterText: String {
        guard let selection = model.importSelection, let free = FreeSpaceProvider.availableBytes else { return "—" }
        let planned = Int64(selection.decodedSampleCount) * 4
        let keepsOriginal = model.importTrashOriginal ? 0 : selection.originalSize
        let freeAfter = free - planned - keepsOriginal
        return byteString(freeAfter)
    }

    private var afterTint: Color? {
        guard let selection = model.importSelection, let free = FreeSpaceProvider.availableBytes else { return nil }
        let planned = Int64(selection.decodedSampleCount) * 4
        let keepsOriginal = model.importTrashOriginal ? 0 : selection.originalSize
        return (free - planned - keepsOriginal) < 0 ? Palette.danger : Palette.ok
    }

    private var importActionLabel: String {
        guard let plan = model.importPlan else { return "" }
        return plan.mode == .wholeParagraph ? String(localized: "audio") : String(localized: "\(plan.slices.count) segments")
    }

    private func formatCaption(_ selection: FlowImportedAudio) -> String {
        var parts: [String] = []
        if let format = selection.format {
            parts.append("\(Int(format.sampleRate)) kHz")
            if let depth = format.bitDepth { parts.append("\(depth)-bit") }
            parts.append(format.channels == 1 ? "mono" : "\(format.channels)ch")
        }
        parts.append(selection.duration.formattedShort)
        return parts.joined(separator: " · ")
    }

    private func sliceCaption(slice: ImportedSlice, rate: Double) -> String {
        guard rate > 0 else { return "slice" }
        let start = Double(slice.startFrame) / rate
        let end = Double(slice.startFrame + slice.frameCount) / rate
        return String(format: "%@ – %@", clockText(start), clockText(end))
    }

    private func clockText(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func kv(_ label: LocalizedStringKey, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).voxFont(.caption).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value)
                .voxFont(.caption, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tint ?? Palette.ink)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Supported inputs: WAV, AIFF, CAF, M4A/AAC, MP3, FLAC (§10).
    static let audioContentTypes: [UTType] = {
        let extensions = ["wav", "aiff", "aif", "caf", "m4a", "aac", "mp3", "flac"]
        return extensions.compactMap { UTType(filenameExtension: $0) }
    }()
}
