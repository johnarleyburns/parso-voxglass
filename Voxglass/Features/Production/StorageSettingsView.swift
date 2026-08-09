import SwiftUI
import VoxglassCore

/// Storage & iCloud (mockup 12, §6.5): the production narration cache and the
/// consumer audiobook download cache are separate budgets. This screen owns the
/// narration working-cache limit, shows the on-device footprint and iCloud
/// backup state, and restates the offload rule — nothing is removed until the
/// iCloud copy is SHA-256-verified.
struct StorageSettingsView: View {
    @State private var model = StorageSettingsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workingCacheCard
                audiobookCacheCard
                iCloudBackupCard
                evictionOrderCard
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
        }
        .background(VoxglassBackground())
        .navigationTitle("Storage & iCloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await model.reload() }
        .accessibilityIdentifier("storage.icloud")
    }

    // MARK: - Narration working cache

    private var workingCacheCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Narration working cache")
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text("\(ByteCountFormatter.string(fromByteCount: model.usedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.limitBytes, countStyle: .file))")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(Palette.ink2)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(Palette.brass)
                        .frame(width: max(8, geo.size.width * min(1, model.fraction)))
                }
            }
            .frame(height: 6)

            VStack(spacing: 6) {
                usageRow("Originals", model.originalBytes)
                usageRow("Renders", model.renderBytes)
                usageRow("Proxies", model.proxyBytes)
                usageRow("Export staging", model.exportBytes)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Limit")
                        .scaledFont(size: 12, weight: .semibold)
                        .foregroundStyle(Palette.ink2)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: model.limitBytes, countStyle: .file))
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(Palette.ink)
                }
                Slider(value: Binding(
                    get: { Double(model.limitGB) },
                    set: { model.setLimitGB(Double(Int($0))) }
                ), in: 2...100, step: 1)
                .tint(Palette.brass)
                .accessibilityIdentifier("storage.workingCacheLimit")
                HStack {
                    Text("2 GB").scaledFont(size: 10).foregroundStyle(Palette.ink3)
                    Spacer()
                    Text("100 GB").scaledFont(size: 10).foregroundStyle(Palette.ink3)
                }
            }
        }
        .glassSurface(cornerRadius: 18)
        .padding(14)
        .accessibilityIdentifier("storage.workingCache")
    }

    private func usageRow(_ label: String, _ bytes: Int64) -> some View {
        HStack {
            Text(label).scaledFont(size: 12.5).foregroundStyle(Palette.ink2)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .scaledFont(size: 12.5, weight: .medium)
                .foregroundStyle(Palette.ink)
        }
    }

    // MARK: - Audiobook downloads

    private var audiobookCacheCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audiobook downloads")
                .scaledFont(size: 16, weight: .bold)
                .foregroundStyle(Palette.ink)
            usageRow("Your listening library", model.audiobookBytes)
            Text("A separate budget. Narration never evicts your downloaded audiobooks, and downloads never evict your takes.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)
        }
        .glassSurface(cornerRadius: 18)
        .padding(14)
        .accessibilityIdentifier("storage.audiobookCache")
    }

    // MARK: - iCloud backup

    private var iCloudBackupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("iCloud backup")
                    .scaledFont(size: 16, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
                statusChip(model.backupRunning ? "Uploading" : "On")
            }

            VStack(spacing: 6) {
                usageRow("Verified in iCloud", model.verifiedCount)
                usageRow("Uploading now", model.uploadingCount)
                usageRow("In your iCloud", model.remoteBytes)
                usageRow("Local only", model.localOnlyCount)
            }

            Text("Nothing is removed until it is safe. A recording can only be offloaded after its iCloud copy is verified byte-for-byte by checksum and the reference is written to this project.")
                .scaledFont(size: 11.5)
                .foregroundStyle(Palette.ink3)
        }
        .glassSurface(cornerRadius: 18)
        .padding(14)
        .accessibilityIdentifier("storage.iCloudBackup")
    }

    // MARK: - Eviction order

    private var evictionOrderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What gets removed first")
                .scaledFont(size: 16, weight: .bold)
                .foregroundStyle(Palette.ink)
            numberedRow(1, "Chapter renders — rebuilt from your takes")
            numberedRow(2, "Staging from finished or cancelled exports")
            numberedRow(3, "Review proxies")
            numberedRow(4, "Verified originals, oldest chapter first")
            Text("Never: local-only takes, uploads in flight, the current chapter, anything you pinned.")
                .scaledFont(size: 11.5)
                .foregroundStyle(NarrationPalette.brassSoft)
                .padding(.top, 4)
        }
        .glassSurface(cornerRadius: 18)
        .padding(14)
        .accessibilityIdentifier("storage.evictionOrder")
    }

    private func numberedRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .scaledFont(size: 11, weight: .heavy)
                .foregroundStyle(NarrationPalette.espresso)
                .frame(width: 20, height: 20)
                .background(Palette.brass, in: Circle())
            Text(text)
                .scaledFont(size: 12.5)
                .foregroundStyle(Palette.ink2)
        }
    }

    private func statusChip(_ label: String) -> some View {
        Text(label)
            .scaledFont(size: 10, weight: .bold)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(Palette.ok)
            .background(Palette.ok.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Palette.ok.opacity(0.4), lineWidth: 1))
    }
}

/// Loads the aggregated storage snapshot for the storage screen (§6.5).
@MainActor
@Observable
final class StorageSettingsModel {
    private let repository = NarrationProjectRepository()
    private var settings = ProductionCacheSettings()

    var usedBytes: Int64 = 0
    var originalBytes: Int64 = 0
    var renderBytes: Int64 = 0
    var proxyBytes: Int64 = 0
    var exportBytes: Int64 = 0
    var audiobookBytes: Int64 = 0
    var verifiedCount: Int64 = 0
    var uploadingCount: Int64 = 0
    var localOnlyCount: Int64 = 0
    var remoteBytes: Int64 = 0
    var backupRunning = false

    var limitBytes: Int64 {
        get { settings.workingCacheBytes }
        set { settings.workingCacheBytes = newValue }
    }

    var limitGB: Int {
        Int(limitBytes / (1024 * 1024 * 1024))
    }

    var fraction: Double {
        guard limitBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(limitBytes))
    }

    func setLimitGB(_ gb: Double) {
        let bytes = Int64(gb) * 1024 * 1024 * 1024
        guard ProductionCacheLimits.isValidWorkingCacheSize(bytes) else { return }
        settings.workingCacheBytes = bytes
    }

    func reload() async {
        let projects = await repository.allProjects()
        var original = Int64(0), render = Int64(0), proxy = Int64(0), staging = Int64(0)
        var verified = Int64(0), uploading = Int64(0), localOnly = Int64(0)
        var remote = Int64(0), backupActive = false

        for project in projects {
            let layout = repository.layout(for: project.id)
            let records = (try? await SQLiteProductionAssetRepository(databaseURL: layout.databaseURL).records()) ?? []
            for record in records {
                switch record.state {
                case .localOnly:
                    localOnly += 1
                    original += record.byteCount
                case .uploading:
                    uploading += 1
                    original += record.byteCount
                    backupActive = true
                case .localAndRemote:
                    verified += 1
                    original += record.byteCount
                    remote += record.byteCount
                case .remoteOnly:
                    remote += record.byteCount
                case .stagedForExport, .missing:
                    break
                }
            }

            let store = FileAssetStore(root: layout.root)
            render += (try? await store.totalBytes(under: .render)) ?? 0
            proxy += (try? await store.totalBytes(under: .proxy)) ?? 0
            staging += Self.directoryBytes(at: layout.exportStagingURL)
        }

        originalBytes = original
        renderBytes = render
        proxyBytes = proxy
        exportBytes = staging
        usedBytes = original + render + proxy + staging
        verifiedCount = verified
        uploadingCount = uploading
        localOnlyCount = localOnly
        remoteBytes = remote
        backupRunning = backupActive

        let cache = StreamCacheStore.shared
        audiobookBytes = await cache.totalCachedBytes()
    }

    private static func directoryBytes(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
