import SwiftUI
import VoxglassCore

/// Reusable validation body shared by the export screen and the early
/// "Check my recording" entry points.
struct ValidationReportView: View {
    @Bindable var model: NarrationFlowModel
    let onFix: (FixAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let blocking = model.blockingValidationIssues
            let warnings = model.validationIssues.filter { $0.severity == .warning }
            HStack {
                Text(model.destinationName)
                    .scaledFont(size: 15, weight: .heavy).foregroundStyle(Palette.ink)
                Spacer()
                Text("\(blocking.count) blocking · \(warnings.count) warnings")
                    .scaledFont(size: 11, weight: .bold)
                    .foregroundStyle(blocking.isEmpty ? Palette.ok : Palette.danger)
            }
            .accessibilityIdentifier("validate.report")

            if let progress = model.metricsProgress {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))) {
                    Text("Analyzing \(progress.done) of \(progress.total)")
                }
            }
            if !blocking.isEmpty { issueSection("BLOCKS EXPORT", issues: blocking) }
            if !warnings.isEmpty { issueSection("WARNINGS", issues: warnings) }
            if blocking.isEmpty && warnings.isEmpty {
                Label("Ready to export — every check passed for \(model.destinationName).", systemImage: "checkmark.seal.fill")
                    .scaledFont(size: 12.5)
                    .foregroundStyle(Palette.ok)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassSurface(cornerRadius: 14)
            }
        }
    }

    private func issueSection(_ title: String, issues: [ValidationIssue]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).scaledFont(size: 12, weight: .bold).foregroundStyle(Palette.ink3)
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.severity == .blocking ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(issue.severity == .blocking ? Palette.danger : Palette.brass)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                        Text(issue.message).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                    }
                    Spacer()
                    if let fix = issue.fix {
                        Button(fixTitle(fix)) { onFix(fix) }
                            .scaledFont(size: 11, weight: .bold)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(11)
                .glassSurface(cornerRadius: 12)
                .accessibilityIdentifier("validation.issue.\(issue.code.rawValue)")
            }
        }
    }

    private func fixTitle(_ fix: FixAction) -> String {
        switch fix {
        case .hydrateAssets: "Download"
        case .manageStorage: "Storage"
        case .backupNow: "Back up"
        case .openAudioSetup: "Audio setup"
        case .recordParagraph: "Record"
        case .clearPickup: "Clear"
        case .regenerateDisclaimers, .regenerateCredits: "Regenerate"
        case .reanalyzeTake: "Re-analyze"
        case .setRetailSample: "Sample"
        case .splitChapter: "Split"
        case .chooseArtwork: "Artwork"
        case .applyMastering: "Master"
        case .goToParagraph, .goToChapter: "Open"
        case .openMetadata: "Edit"
        case .openRights: "Rights"
        case .selectTake: "Select"
        }
    }
}

struct ValidationReportSheet: View {
    @Bindable var model: NarrationFlowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Image(systemName: "checkmark.circle")
                        .frame(width: 1, height: 1)
                        .opacity(0.01)
                        .accessibilityIdentifier("validation.reportSheet")
                    ValidationReportView(model: model, onFix: apply)
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationTitle("Recording check")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Re-analyze all") { Task { await model.recomputeAllMetrics() } }
                        .disabled(model.metricsProgress != nil)
                        .accessibilityIdentifier("validation.reanalyzeAll")
                }
            }
        }
    }

    private func apply(_ fix: FixAction) {
        switch fix {
        case .reanalyzeTake(let takeID):
            Task { await model.recomputeMetrics(takeIDs: [takeID]); await model.runValidation() }
        case .hydrateAssets:
            Task { await model.hydrateAllForExport(); await model.runValidation() }
        case .backupNow:
            Task { _ = await model.saveCopyOfProject() }
        case .clearPickup(let paragraphID):
            Task { await model.clearPickup(paragraphID) }
        case .regenerateDisclaimers:
            Task { await model.regenerateScript(for: .librivox) }
        case .regenerateCredits:
            Task { await model.regenerateScript(for: .acx) }
        case .applyMastering:
            model.applyMasteringForExport = true
            Task { await model.runValidation() }
        case .setRetailSample:
            Task { await model.setDefaultRetailSampleForExport() }
        case .goToParagraph, .recordParagraph, .selectTake, .goToChapter, .splitChapter,
             .openMetadata, .openRights, .chooseArtwork, .manageStorage, .openAudioSetup:
            model.pendingFixAction = fix
            dismiss()
        }
    }
}
