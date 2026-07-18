import StoreKit
import SwiftUI
import VoxglassCore

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

    /// Ordered high-value first. Every entry must have a real
    /// `ProFeature.isEnabled(_:)` gate (guard_wiring.sh Rule 4 +
    /// `ProPaywallContentTests`).
    static let advertised: [ProFeatureAdvertisement] = [
        ProFeatureAdvertisement(
            feature: .offlineDownloads,
            icon: "arrow.down.circle.fill",
            title: "Unlimited Offline Downloads",
            description: "Download as many books as you want for gap-free listening anywhere. Free tier lets you pin 2."
        ),
        ProFeatureAdvertisement(
            feature: .cachePresets,
            icon: "internaldrive.fill",
            title: "Bigger Streaming Cache",
            description: "2 GB and 10 GB presets keep far more audio ready to play offline."
        ),
        ProFeatureAdvertisement(
            feature: .prefetchDepth,
            icon: "arrow.triangle.branch",
            title: "Whole-Book Prefetch",
            description: "Preload the next 3 chapters or the entire book so playback never waits."
        ),
        ProFeatureAdvertisement(
            feature: .icloudSync,
            icon: "icloud.fill",
            title: "Bookmarks & Favorites Sync",
            description: "Sync your bookmarks and favorites across your devices via your private iCloud account. Your playback position syncs free, for everyone."
        ),
        ProFeatureAdvertisement(
            feature: .folderWatch,
            icon: "folder.fill.badge.plus",
            title: "Folder Watch",
            description: "Point Voxglass at a folder of audio files — new files appear automatically."
        ),
        ProFeatureAdvertisement(
            feature: .eq,
            icon: "waveform.path.ecg",
            title: "10-Band EQ",
            description: "Shape playback with custom or preset EQs."
        ),
        ProFeatureAdvertisement(
            feature: .listeningStats,
            icon: "chart.bar.fill",
            title: "Listening Stats",
            description: "Track your listening habits — total time, genres, authors, and daily streaks."
        ),
        ProFeatureAdvertisement(
            feature: .libraryBackup,
            icon: "externaldrive.badge.timemachine",
            title: "Library Backup & Restore",
            description: "Export your books, positions, bookmarks, and playlists to a file you control. Import to restore on any device."
        )
    ]

    private var features: [ProFeatureAdvertisement] { Self.advertised }

    var body: some View {
        ZStack {
            VoxglassTheme.libraryBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    featuresSection
                    purchaseSection
                    foreverFreeFooter
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
        .onChange(of: storeManager.isPro) { _, isPro in
            guard isPro else { return }
            Task { try? await Task.sleep(for: .seconds(1.2)); dismiss() }
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
                .foregroundStyle(Palette.ink)

            Text("One-time purchase. No subscription.\nNo account required.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)

            Text("One-time. Less than a month of Audible — and every book is free, forever.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
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
        .padding(.bottom, 28)
    }

    private var purchaseSection: some View {
        VStack(spacing: 14) {
            if storeManager.isPro {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .scaledFont(size: 44)
                        .foregroundStyle(Palette.brass)

                    Text("Pro Unlocked")
                        .scaledFont(size: 20, weight: .bold)
                        .foregroundStyle(Palette.ink)

                    Button {
                        dismiss()
                    } label: {
                        Text("Continue")
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
                }
                .accessibilityIdentifier("paywall.success")
            } else if let product = storeManager.products.first {
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

            if !storeManager.isPro {
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
            }

            if let error = storeManager.purchaseError {
                Text(error)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.danger)
                    .padding(.top, 4)
            }
        }
    }

    private var foreverFreeFooter: some View {
        VStack(spacing: 4) {
            Text("Speed 0.5–3.5× · Sleep timer · Bookmarks · Position sync across devices · Lock-screen artwork · Per-chapter narrators · Volume normalization · Skip silence · FLAC & MP3 · No ads · No telemetry · No accounts — stays free forever.")
                .scaledFont(size: 10)
                .foregroundStyle(Palette.ink3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .padding(.top, 20)
    }
}
