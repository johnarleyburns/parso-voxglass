import AppKit
import SwiftUI
import VoxglassCore

/// The Export wizard (§16.11, §18.1.15; mockup `14-export-wizard`).
///
/// Three steps — scope → destination → confirm & run — plus running and done
/// states. The Pro gate is checked at the step 2→3 transition: an unlicensed
/// retail choice surfaces an inline purchase sheet and, on success, continues
/// with all selections preserved.
struct ExportWizardView: View {
    @Environment(StudioEnvironment.self) private var env
    @Bindable var model: ExportModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .sheet(isPresented: $model.showPurchase) {
            PurchaseSheet(model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            ForEach([ExportStep.scope, .destination, .confirm], id: \.self) { step in
                Text(stepLabel(step))
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(highlight(step) ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            if let card = model.card {
                Text(card.isPro ? "Pro · $149" : "Free")
                    .font(.caption.bold())
                    .foregroundStyle(card.isPro ? .orange : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func stepLabel(_ step: ExportStep) -> String {
        switch step {
        case .scope: "1 · Scope"
        case .destination: "2 · Destination"
        case .confirm: "3 · Confirm"
        case .running: "Exporting"
        case .done: "Complete"
        }
    }

    private func highlight(_ step: ExportStep) -> Bool {
        model.step == step
            || (step == .confirm && (model.step == .running || model.step == .done))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .scope: scopeStep
        case .destination: destinationStep
        case .confirm: confirmStep
        case .running: runningStep
        case .done: doneStep
        }
    }

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What to export")
                .font(.title2.bold())
            Text("LibriVox's real workflow posts one section at a time — export a single chapter whenever you like.")
                .foregroundStyle(.secondary)

            Picker("Scope", selection: $model.scope) {
                Text("Whole book").tag(ExportScope.wholeBook)
                Text("Selected chapters").tag(ExportScope.chapters(Array(model.selectedChapterIDs)))
                Text("Single chapter").tag(ExportScope.chapters(Array(model.selectedChapterIDs)))
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("export.scope.\(scopeKey)")

            if model.scope != .wholeBook {
                List(model.project.chapters, id: \.id) { chapter in
                    Button {
                        toggle(chapter.id)
                    } label: {
                        HStack {
                            Image(systemName: model.selectedChapterIDs.contains(chapter.id)
                                  ? "checkmark.circle.fill" : "circle")
                            Text(chapter.title)
                            Spacer()
                            Text("\(chapter.paragraphs.count) ¶")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(minHeight: 180)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func toggle(_ id: UUID) {
        if model.selectedChapterIDs.contains(id) {
            model.selectedChapterIDs.remove(id)
        } else {
            model.selectedChapterIDs.insert(id)
        }
    }

    private var scopeKey: String {
        switch model.scope {
        case .wholeBook: "wholeBook"
        case .chapters(let ids): ids.count == 1 ? "single" : "selected"
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a destination")
                .font(.title2.bold())
            ForEach(ExportCard.allCases) { card in
                Button {
                    model.card = card
                } label: {
                    destinationCard(card)
                }
                .buttonStyle(.plain)
                .disabled(disabledReason(card) != nil)
                .opacity(disabledReason(card) == nil ? 1 : 0.45)
                .accessibilityIdentifier(card.accessibilityIdentifier)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func destinationCard(_ card: ExportCard) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.card == card ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.card == card ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(card.title).font(.headline)
                    Text(card.isPro ? "Pro · $149" : "Free")
                        .font(.caption.bold())
                        .foregroundStyle(card.isPro ? .orange : .green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((card.isPro ? Color.orange : Color.green).opacity(0.15))
                        .clipShape(Capsule())
                }
                Text(card.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = disabledReason(card) {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(model.card == card ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            model.card == card ? Color.accentColor : Color.gray.opacity(0.3)
        ))
        .contentShape(Rectangle())
    }

    private func disabledReason(_ card: ExportCard) -> String? {
        if !model.availableEncoders.contains(card.primaryCodec) {
            return "The \(card.primaryCodec) encoder could not be loaded. Reinstall Voxglass Studio."
        }
        switch card {
        case .librivox:
            if !model.eligibility.librivoxEligible {
                return "Not eligible: AI-origin narration is present in the selected takes."
            }
        case .internetArchive:
            if model.project.metadata.archiveIdentifier == nil {
                return "Set an archive identifier in Metadata & Rights first."
            }
        case .retail:
            break
        }
        return nil
    }

    private var confirmStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Confirm & export")
                    .font(.title2.bold())

                GroupBox("Validation — \(model.card?.title ?? "")") {
                    HStack(spacing: 16) {
                        VStack {
                            Text("\(model.blockingCount)").font(.title.bold())
                            Text("blocking").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack {
                            Text("\(model.eligibility.humanParagraphCount)").font(.title.bold())
                            Text("human ¶").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack {
                            Text("\(model.eligibility.aiParagraphCount)").font(.title.bold())
                            Text("AI ¶").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if model.blockingCount > 0 {
                        Text("Export blocked — \(model.blockingCount) blocking issue(s) must be fixed before exporting to \(model.card?.title ?? "").")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.top, 6)
                    }
                }

                GroupBox("Options") {
                    VStack(alignment: .leading, spacing: 10) {
                        switch model.card {
                        case .internetArchive:
                            Toggle("Include 192 kbps MP3 derivatives", isOn: $model.includeMP3Derivatives)
                            Toggle("Use the community test collection (auto-purged dry run)", isOn: $model.useTestCollection)
                        case .retail:
                            Toggle("Apply the mastering chain", isOn: $model.applyMastering)
                            HStack {
                                Text("M4B bitrate")
                                Picker("", selection: $model.m4bBitrateKbps) {
                                    Text("64").tag(64)
                                    Text("96").tag(96)
                                    Text("128").tag(128)
                                    Text("192").tag(192)
                                }
                                .frame(width: 90)
                            }
                            Picker("Retail profile", selection: $model.retailProfile) {
                                Text("ACX / Audible").tag(DestinationID.acx)
                                Text("Apple Books / Aggregator").tag(DestinationID.appleBooksAggregator)
                            }
                        case .librivox, nil:
                            EmptyView()
                        }
                        Toggle("Write the validation report into the package", isOn: $model.writeValidationReport)
                        Text("Output: \(model.outputRoot.path)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
        }
    }

    private var runningStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exporting to \(model.card?.title ?? "")")
                .font(.title2.bold())
            if let progress = model.progress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fractionCompleted)
                    Text(progress.currentFileName ?? progress.phase.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(Color.black.opacity(0.05))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export complete")
                .font(.title2.bold())
            if let bundle = model.completedBundle {
                Text("\(bundle.files.count) files · \(PackagingSupport.clockTime(bundle.totalDuration)) · \(ByteCountFormatter.string(fromByteCount: bundle.totalBytes, countStyle: .file))")
                Text("Everything was prepared — uploading to any destination is your action, not Voxglass's.")
                    .foregroundStyle(.secondary)
                Text("Reveal the package:")
                    .font(.headline)
                Text(bundle.rootURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .background(Color.black.opacity(0.05))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if model.step != .scope && model.step != .done {
                Button("Back") {
                    model.back()
                }
                .disabled(model.step == .running)
            }
            Spacer()
            switch model.step {
            case .scope:
                Button("Continue") {
                    Task { _ = await model.next() }
                }
                .buttonStyle(.borderedProminent)
            case .destination:
                Button("Continue") {
                    Task { _ = await model.next() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.card == nil)
            case .confirm:
                Button("Export") {
                    model.run()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
                .accessibilityIdentifier("export.run")
            case .running:
                Button("Cancel") {
                    model.cancel()
                }
                .accessibilityIdentifier("export.cancel")
            case .done:
                Button("Reveal in Finder") {
                    if let url = model.completedBundle?.rootURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .accessibilityIdentifier("export.revealInFinder")
                Button("Close") {
                    env.navigate(to: .dashboard)
                }
            }
        }
        .padding(16)
    }
}

// MARK: - PurchaseSheet

/// The inline purchase surface shown when a Pro destination is selected
/// without an entitlement (§2.4, §17.5). Purchase never blocks an
/// in-progress action; it appears at the step 2→3 transition, before any
/// export work.
struct PurchaseSheet: View {
    @Environment(StudioEnvironment.self) private var env
    @Bindable var model: ExportModel
    @State private var product: ProductInfo? = nil
    @State private var isPurchasing = false
    @State private var message: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Voxglass Studio Pro")
                .font(.title2.bold())
            Text(product?.displayPrice ?? "Unlock Pro")
                .font(.title3.bold())
                .foregroundStyle(.orange)
            Text("Professional retail delivery is part of Voxglass Studio Pro — a one-time $149 purchase. Everything you have already done stays free.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restore Purchases") {
                    Task { await restore() }
                }
                .accessibilityIdentifier("settings.restorePurchases")
                Button("Purchase") {
                    Task { await purchase() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPurchasing)
                .accessibilityIdentifier("export.unlockPro")
            }
            Button("Not now") {
                model.showPurchase = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360)
        .task {
            await loadProduct()
        }
    }

    private func loadProduct() async {
        if let info = try? await env.license.provider.product() {
            product = info
        }
    }

    private func purchase() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let state = try await env.license.provider.purchasePro()
            switch state {
            case .pro:
                _ = await model.resumeAfterPurchase()
            case .pending:
                message = "Waiting for approval — your selections are saved and the export will continue once approved."
            case .free, .unknown:
                message = "The purchase did not complete. Please try again."
            }
        } catch LicenseError.cancelled {
            // The user backed out of the sheet; keep the wizard as-is.
        } catch {
            message = error.localizedDescription
        }
    }

    private func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let state = try await env.license.provider.restore()
            switch state {
            case .pro:
                _ = await model.resumeAfterPurchase()
            case .free:
                message = "No previous purchase was found for this Apple ID."
            default:
                message = "Restore could not be confirmed."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
