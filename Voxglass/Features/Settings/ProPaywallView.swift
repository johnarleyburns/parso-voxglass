import StoreKit
import SwiftUI

/// A single advertised Pro feature, tied to its `ProFeature` gate so the paywall
/// copy, the entitlement enum, and the free-tier registry stay in lockstep
/// (enforced by `ProPaywallContentTests`).
struct ProFeatureAdvertisement: Identifiable {
    let feature: ProFeature
    let icon: String
    let title: String
    let description: String

    var id: String { feature.rawValue }
}

struct ProPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var storeManager = StoreManager.shared

    /// Ordered high-value first. Every `ProFeature` must appear exactly once.
    static let advertised: [ProFeatureAdvertisement] = [
        ProFeatureAdvertisement(
            feature: .eq,
            icon: "waveform.path.ecg",
            title: "10-Band EQ + Volume Normalization",
            description: "Shape playback with custom or preset EQs; automatic volume leveling keeps uneven LibriVox recordings comfortable."),
        ProFeatureAdvertisement(
            feature: .folderWatch,
            icon: "folder.fill.badge.plus",
            title: "Folder Watch",
            description: "Point Voxglass at a folder of audio files — new files appear automatically."),
        ProFeatureAdvertisement(
            feature: .icloudSync,
            icon: "icloud.fill",
            title: "iCloud Sync",
            description: "Sync playback positions, bookmarks, and favorites across your devices via your private iCloud account."),
        ProFeatureAdvertisement(
            feature: .listeningStats,
            icon: "chart.bar.fill",
            title: "Listening Stats",
            description: "Track your listening habits — total time, genres, authors, and daily streaks."),
        ProFeatureAdvertisement(
            feature: .offlineDownloads,
            icon: "arrow.down.circle.fill",
            title: "Unlimited Offline Pins",
            description: "Download as many books as you want for gap-free listening offline. Free tier lets you pin a couple."),
        ProFeatureAdvertisement(
            feature: .cachePresets,
            icon: "square.split.2x2.fill",
            title: "Cache Presets",
            description: "Choose 500 MB, 2 GB, or 10 GB streaming cache to keep more audio available offline."),
        ProFeatureAdvertisement(
            feature: .prefetchDepth,
            icon: "arrow.triangle.branch",
            title: "Prefetch Depth",
            description: "Prefetch the next few chapters or your whole book over Wi-Fi so playback never waits.")
    ]

    private var features: [ProFeatureAdvertisement] { Self.advertised }

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
                .scaledFont(size: 48)
                .foregroundStyle(Palette.brass)
                .padding(.top, 24)

            Text("Voxglass Pro")
                .scaledFont(size: 31, weight: .heavy)
                .kerning(-0.5)
                .foregroundStyle(Palette.ink)

            Text("One-time purchase. No subscription.\nNo account required.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 32)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pro features")
                .scaledFont(size: 18, weight: .bold)
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(features.indices, id: \.self) { index in
                    let feature = features[index]
                    HStack(spacing: 14) {
                        Image(systemName: feature.icon)
                            .scaledFont(size: 16)
                            .frame(width: 28)
                            .foregroundStyle(Palette.brass)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .scaledFont(size: 14, weight: .medium)
                                .foregroundStyle(Palette.ink)
                            Text(feature.description)
                                .scaledFont(size: 11.5)
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
                .scaledFont(size: 16, weight: .semibold)
                .foregroundStyle(Palette.ink)

            Text("FLAC, MP3 playback · Near-gapless · Internet Archive & LibriVox sources · Local file import · No telemetry, no accounts")
                .scaledFont(size: 11.5)
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
                        .scaledFont(size: 15.5, weight: .bold)
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
                    .scaledFont(size: 14)
                    .foregroundStyle(Palette.ink2)
            }
            .disabled(storeManager.isRestoring)

            if let error = storeManager.purchaseError {
                Text(error)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.danger)
                    .padding(.top, 4)
            }

            Text("You can also build Pro from source —\nvisit the repository for instructions.")
                .scaledFont(size: 11)
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
    }
}
