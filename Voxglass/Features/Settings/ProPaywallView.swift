import StoreKit
import SwiftUI

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared

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
        ZStack {
            VoxglassTheme.libraryBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    featuresSection
                    foreverFreeSection
                    purchaseSection
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Voxglass Pro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
                    .foregroundStyle(Palette.ink2)
            }
        }
        .task {
            await storeManager.loadProducts()
        }
    }

    private var heroSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 48))
                .foregroundStyle(Palette.brass)
                .padding(.top, 24)

            Text("Voxglass Pro")
                .font(.system(size: 31, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(Palette.ink)

            Text("One-time purchase. No subscription.\nNo account required.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 32)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pro features")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(features.indices, id: \.self) { index in
                    let feature = features[index]
                    HStack(spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 16))
                            .frame(width: 28)
                            .foregroundStyle(Palette.brass)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Palette.ink)
                            Text(feature.description)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Palette.ink3)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
            }
            .glassSurface(cornerRadius: 14)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 32)
    }

    private var foreverFreeSection: some View {
        VStack(spacing: 8) {
            Text("Stays free forever")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)

            Text("FLAC, Opus, MP3 playback · Near-gapless · Internet Archive & LibriVox sources · Local file import · No telemetry, no accounts")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.ink3)
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
                    Text("Unlock Pro — \(product.displayPrice)")
                        .font(.system(size: 15.5, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(Color(hex: 0x221503))
                        .background {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                    startPoint: .top, endPoint: .bottom))
                        }
                }
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
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
            }
            .disabled(storeManager.isRestoring)

            if let error = storeManager.purchaseError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.danger)
                    .padding(.top, 4)
            }

            Text("You can also build Pro from source —\nvisit the repository for instructions.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }
}
