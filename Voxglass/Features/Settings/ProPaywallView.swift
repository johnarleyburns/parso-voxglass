import StoreKit
import SwiftUI

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared
    @State private var selectedProduct: Product?

    private let features: [(icon: String, title: String, description: String)] = [
        ("square.split.2x2.fill", "Cache Presets",
         "Choose 500 MB, 2 GB, or 10 GB streaming cache to keep more music available offline."),
        ("arrow.triangle.branch", "Prefetch Depth",
         "Prefetch the next N tracks or your whole queue over Wi-Fi so playback never waits."),
        ("folder.fill.badge.plus", "Folder Watch",
         "Point Voxglass at a folder of audio files — new files appear automatically."),
        ("waveform.path.ecg", "10-Band EQ",
         "MTAudioProcessingTap with biquad filters. Presets for Concert Hall, Spoken Word, 78 rpm, and your own."),
        ("car.fill", "CarPlay (when ready)",
         "CarPlay support will ship as a Pro feature in a future update.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    featuresSection
                    foreverFreeSection
                    purchaseSection
                }
                .padding(.bottom, 32)
            }
            .navigationTitle("Voxglass Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await storeManager.loadProducts()
            }
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .padding(.top, 24)

            Text("Voxglass Pro")
                .font(.largeTitle.bold())

            Text("One-time purchase. No subscription.\nNo account required.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 32)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pro features")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            ForEach(features.indices, id: \.self) { index in
                let feature = features[index]
                HStack(spacing: 14) {
                    Image(systemName: feature.icon)
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.body.weight(.medium))
                        Text(feature.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                if index < features.count - 1 {
                    Divider().padding(.leading, 62)
                }
            }
        }
        .padding(.bottom, 32)
    }

    private var foreverFreeSection: some View {
        VStack(spacing: 8) {
            Text("Stays free forever")
                .font(.headline)

            Text("FLAC, Opus, MP3 playback · Near-gapless · Internet Archive & LibriVox sources · Local file import · No telemetry, no accounts")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.bottom, 28)
    }

    private var purchaseSection: some View {
        VStack(spacing: 14) {
            if let product = storeManager.products.first {
                Button {
                    Task {
                        await storeManager.purchase(product)
                    }
                } label: {
                    HStack {
                        Text("Unlock Pro — \(product.displayPrice)")
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 20)
            } else {
                ProgressView()
                    .padding(.vertical, 14)
            }

            Button {
                Task {
                    await storeManager.restorePurchases()
                }
            } label: {
                Text(storeManager.isRestoring ? "Restoring…" : "Restore Purchases")
                    .font(.subheadline)
            }
            .disabled(storeManager.isRestoring)

            if let error = storeManager.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            Text("You can also build Pro from source —\nvisit the repository for instructions.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }
}
