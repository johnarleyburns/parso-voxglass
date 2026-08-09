import SwiftUI
import VoxglassCore

/// The Pro purchase sheet (mockup 14c, §13.5). Reachable from exactly two places:
/// the export destination picker (retail) and Settings. Display name per decision
/// D-1 ("Voxglass Narration Pro"); the price is read from StoreKit at runtime —
/// it is never hardcoded in code (§2.2, D-2).
///
/// Validation is free for every destination, so the sheet previews the project's
/// ACX readiness before any purchase. Restore Purchases is always visible. A
/// refund or revocation returns the app to free while preserving every project.
struct ProPurchaseView: View {
    let provider: any LicenseProvider
    var model: NarrationFlowModel?
    let onPurchased: (EntitlementState) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var productInfo: ProductInfo?
    @State private var acxIssues: [ValidationIssue] = []
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header

                    featureList

                    freeStaysFreeBanner

                    if let model {
                        readinessPreview
                    }

                    purchaseButton

                    restoreButton

                    Text("One-time purchase, not a subscription. If it is ever refunded, your projects, takes, and recordings stay exactly where they are.")
                        .scaledFont(size: 11)
                        .foregroundStyle(Palette.ink3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                productInfo = try? await provider.product()
                if model != nil {
                    acxIssues = await model?.acxReadinessPreview() ?? []
                }
            }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.brass.opacity(0.9), Palette.brassDeep], startPoint: .top, endPoint: .bottom))
                Image(systemName: "sparkles").scaledFont(size: 34, weight: .bold).foregroundStyle(NarrationPalette.espresso)
            }
            .frame(width: 84, height: 84)
            .padding(.top, 10)

            Text("Commercial release")
                .scaledFont(size: 22, weight: .heavy)
                .foregroundStyle(Palette.ink)
            Text("Everything you need to deliver a paid audiobook — once, not monthly.")
                .scaledFont(size: 12.5)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            featureRow("Retail destination profiles", "ACX / Audible, Apple Books, aggregators, generic retail", symbol: "building.2.fill")
            featureRow("Mastering chain", "Hits ACX loudness, peak, and noise targets", symbol: "slider.horizontal.3")
            featureRow("Chapterized M4B", "Real chapter marks, playable everywhere", symbol: "book.closed.fill")
            featureRow("Commercial FLAC masters", "Archive-grade delivery files", symbol: "waveform")
            featureRow("Whole-book batch export", "Unattended and resumable", symbol: "square.stack.3d.up.fill")
            featureRow("Commercial metadata & retail sample", "ISBN/ASIN, publisher, rights holder, copyright", symbol: "tag.fill")
            featureRow("Validation reports as files", "HTML or JSON, for a client or a rights holder", symbol: "doc.text.fill")
        }
        .padding(.horizontal, 14)
        .glassSurface(cornerRadius: 18)
    }

    private func featureRow(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(Palette.brass)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                    Text(detail).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            VoxglassListDivider()
        }
    }

    private var freeStaysFreeBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Free stays free").scaledFont(size: 13, weight: .bold).foregroundStyle(Palette.ok)
            Text("Unlimited recording, review, Apple Watch, iCloud backup, LibriVox export, and Internet Archive export with FLAC masters — none of that is behind this purchase, and none of it ever will be.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.ok.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ok.opacity(0.35), lineWidth: 1))
    }

    /// The project's free ACX check (mockup 14c "Your project right now").
    @ViewBuilder
    private var readinessPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your project right now").scaledFont(size: 13, weight: .semibold).foregroundStyle(Palette.ink)
                Spacer()
                Text("Checked against ACX for free")
                    .scaledFont(size: 10.5, weight: .bold)
                    .foregroundStyle(Palette.ink3)
            }
            let blocking = acxIssues.filter { $0.severity == .blocking }
            HStack(spacing: 8) {
                Image(systemName: blocking.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(blocking.isEmpty ? Palette.ok : Palette.brass)
                Text(blocking.isEmpty
                    ? "Would pass ACX"
                    : "\(blocking.count) issue\(blocking.count == 1 ? "" : "s") to resolve first")
                    .scaledFont(size: 12.5, weight: .bold)
                    .foregroundStyle(Palette.ink)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 14)
    }

    private var purchaseButton: some View {
        Button {
            Task { await purchase() }
        } label: {
            HStack(spacing: 8) {
                if isPurchasing {
                    ProgressView().tint(NarrationPalette.espresso)
                }
                Text(purchaseTitle)
                    .scaledFont(size: 15, weight: .heavy)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(NarrationPalette.espresso)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || isRestoring)
        .accessibilityIdentifier("pro.purchase")
    }

    private var purchaseTitle: String {
        if let productInfo {
            return "Unlock — \(productInfo.displayPrice)"
        }
        return "Unlock — one-time purchase"
    }

    private var restoreButton: some View {
        Button {
            Task { await restore() }
        } label: {
            Text(isRestoring ? "Restoring…" : "Restore purchase")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Palette.brass.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.brass.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || isRestoring)
        .accessibilityIdentifier("pro.restore")
    }

    private func purchase() async {
        isPurchasing = true
        error = nil
        defer { isPurchasing = false }
        do {
            let state = try await provider.purchasePro()
            onPurchased(state)
            dismiss()
        } catch LicenseError.cancelled {
            // The user dismissed the App Store sheet.
        } catch LicenseError.proRequired {
            // Not applicable to purchase.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore() async {
        isRestoring = true
        error = nil
        defer { isRestoring = false }
        do {
            let state = try await provider.restore()
            onPurchased(state)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
