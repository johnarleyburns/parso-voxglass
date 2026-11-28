import Foundation
import Testing
@testable import VoxglassCore

/// Platform views need physical-device tests. These guards cover ownership of
/// transfer consent/results and the pure summary used by the single sync surface.
@Suite struct WatchTransferUIContractTests {
    @Test func syncOwnsTransferConsentAndResults() throws {
        let text = try source("Voxglass/Features/Settings/SettingsView.swift")
        #expect(text.contains("struct SyncSettingsSection: View"))
        #expect(text.contains("Send to Apple Watch on cellular data?"))
        #expect(text.contains("case .needsCellularConfirmation"))
        #expect(text.contains("case .failed(let message)"))
        #expect(text.contains("pauseBookTransferToWatch"))
        #expect(text.contains("cancelWatchPreparation"))
        #expect(text.contains("sync.books"))
    }

    @Test func playerAndLibraryDoNotOwnWatchTransport() throws {
        for path in ["Voxglass/Features/Player/BookPageView.swift",
                     "Voxglass/Features/Player/BookPageActionRow.swift",
                     "Voxglass/Features/Library/LibraryView.swift"] {
            let text = try source(path)
            #expect(!text.contains("transferBookToWatch("), "\(path)")
            #expect(!text.contains("retryStalledBookTransferToWatch("), "\(path)")
            #expect(!text.contains("Download to Apple Watch?"), "\(path)")
        }
        // The overflow sheet owns the restored single-book quick action
        // (alongside Settings' batch flow) — see
        // BookPageWatchDownloadContractTests.overflowSheetOwnsTheSingleBookQuickAction.
        // It still must not own retry or the old removed confirmation dialog.
        let overflow = try source("Voxglass/Features/Player/BookPageOverflowSheet.swift")
        #expect(overflow.contains("transferBookToWatch("))
        #expect(!overflow.contains("retryStalledBookTransferToWatch("))
        #expect(!overflow.contains("Download to Apple Watch?"))
    }

    @Test func aboutOwnsDiagnosticsAndRecovery() throws {
        let phone = try source("Voxglass/Features/Settings/SettingsView.swift")
        #expect(phone.contains("struct SyncDiagnosticsView: View"))
        #expect(phone.contains("DisclosureGroup(\"Connection\")"))
        #expect(phone.contains("DisclosureGroup(\"Apple Watch\")"))
        #expect(!phone.contains("DisclosureGroup(\"iCloud Sync\")"))
        #expect(!phone.contains("private struct WatchSyncCard"))
        let watch = try source("VoxglassWatch/WatchAboutView.swift")
        #expect(watch.contains("WatchListeningSyncStatusView()"))
        #expect(watch.contains("Reset watch listening data"))
        let watchDetails = try source("VoxglassWatch/WatchListeningViews.swift")
        #expect(!watchDetails.contains("DisclosureGroup"))
        #expect(watchDetails.contains("NavigationLink(\"Diagnostics\")"))
        let home = try source("VoxglassWatch/WatchLibraryView.swift")
        #expect(home.contains("services.session.syncNow()"))
        #expect(!home.contains("path.append(.downloads)"))
        #expect(!home.contains("path.append(.syncStatus)"))
    }

    @Test func explicitSyncClearsAStaleAttentionErrorBeforeGuards() throws {
        let relay = try source("Voxglass/App/PhoneAudioRelay.swift")
        #expect(relay.contains("func beginSyncAttempt()"))
        #expect(relay.contains("watchSyncError = nil\n        watchTransferError = nil\n        watchSyncStatus = nil"))
        let start = try #require(relay.range(of: "func syncWatchNow() async {"))
        let body = String(relay[start.lowerBound...])
        let clear = try #require(body.range(of: "beginSyncAttempt()"))
        let pairingGuard = try #require(body.range(of: "guard isPaired"))
        #expect(clear.lowerBound < pairingGuard.lowerBound)

        let settings = try source("Voxglass/Features/Settings/SettingsView.swift")
        #expect(settings.contains("relay.beginSyncAttempt()"))
        #expect(settings.contains("watchsync.stalled.retry"))
    }

    @Test func sentCatalogIsNeverConfirmedAudio() {
        let state = WatchSyncPresentation(isReachable: true, selectedCount: 1,
                                          pendingCount: 1, installedCount: 0)
        #expect(state.phase == .waiting)
        #expect(!state.showsProgress)
    }

    @Test func installedRequiresEverySelectedBookToBeConfirmed() {
        #expect(WatchSyncPresentation(isReachable: true, selectedCount: 2,
                                     installedCount: 1).phase == .waiting)
        #expect(WatchSyncPresentation(isReachable: true, selectedCount: 2,
                                     installedCount: 2).phase == .installed)
    }

    @Test func pausedFailedAndDisconnectedAreNotAnimatedProgress() {
        #expect(WatchSyncPresentation(isReachable: true, failedCount: 1).phase == .failed)
        #expect(WatchSyncPresentation(isReachable: true, pausedCount: 1).phase == .paused)
        #expect(WatchSyncPresentation(isReachable: false, pendingCount: 1).phase == .disconnected)
        #expect(!WatchSyncPresentation(isReachable: true, failedCount: 1).showsProgress)
        #expect(!WatchSyncPresentation(isReachable: true, pausedCount: 1).showsProgress)
    }

    @Test func onlyRealPreparationOrRequestShowsProgress() {
        #expect(WatchSyncPresentation(isReachable: true, isPreparing: true).showsProgress)
        #expect(WatchSyncPresentation(isReachable: true, isRequesting: true).showsProgress)
        #expect(!WatchSyncPresentation(isReachable: true).showsProgress)
    }

    @Test func lateInventoryDoesNotSilentlyDeselectBooks() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        #expect(WatchSyncSelection.reconcile(selected: [], baseline: [], latest: [id]) == [id])
    }

    @Test func inventoryRefreshPreservesStagedAdditionsAndRemovals() {
        let old = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let added = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let incoming = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        #expect(WatchSyncSelection.reconcile(selected: [added], baseline: [old], latest: [old, incoming]) == [added, incoming])
    }

    @Test func readByAIIsRejectedEvenWithRecordedLookingChapters() {
        #expect(!WatchDownloadEligibility.allowsTransfer(isReadByAI: true, chapterExtensions: ["m4a"]))
        #expect(!WatchDownloadEligibility.allowsTransfer(isReadByAI: false, chapterExtensions: ["VOXTEXT"]))
        #expect(!WatchDownloadEligibility.allowsTransfer(isReadByAI: false, chapterExtensions: ["mp3", "voxtext"]))
        #expect(WatchDownloadEligibility.allowsTransfer(isReadByAI: false, chapterExtensions: ["mp3", "m4a"]))
    }

    @Test func readByAIBlockRunsBeforeWatchReadinessAndPreparation() throws {
        let relay = try source("Voxglass/App/PhoneAudioRelay.swift")
        let gate = try #require(relay.range(of: "guard WatchDownloadEligibility.allowsTransfer("))
        let preparation = try #require(relay.range(of: "switch WatchSendReadinessResolver.resolve("))
        #expect(gate.lowerBound < preparation.lowerBound)
        #expect(!relay.contains("ReadWithAIWatchNarrationRenderer("))
        let retiredRenderer = try source("Voxglass/App/ReadWithAIWatchNarrationRenderer.swift")
        #expect(!retiredRenderer.contains("AVSpeechSynthesizer"))
        #expect(retiredRenderer.contains("@available(*, unavailable"))
        let row = try source("Voxglass/Features/Player/BookPageActionRow.swift")
        #expect(row.contains("ReadByAIWatchInfoButton()"))
        let sync = try source("Voxglass/Features/Settings/SettingsView.swift")
        #expect(sync.contains("watchDownloadSupported(book)"))
        #expect(sync.contains("struct ReadByAIWatchInfoButton: View"))
    }

    @Test func activeTransferIsDistinctFromWaitingForInstallation() {
        let transfer = WatchSyncPresentation(isReachable: true, selectedCount: 1, transferringCount: 1)
        #expect(transfer.phase == .transferring)
        #expect(!transfer.showsProgress)
    }

    @Test func oldWatchTimeoutCannotOverrideNewRequest() throws {
        let watch = try source("VoxglassWatch/WatchSessionAdapter.swift")
        #expect(watch.contains("syncGeneration == generation"))
        #expect(watch.contains("self.syncGeneration == generation"))
        #expect(watch.contains("syncNeedsAttention = true"))
        #expect(!watch.contains("try? await Task.sleep(for: .seconds(8))"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
