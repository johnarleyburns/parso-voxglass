import SwiftUI
import VoxglassCore

struct WatchFetchStatusView: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices
    @EnvironmentObject var offlineManager: WatchStorageManager
    @Environment(\.dismiss) private var dismiss

    private var state: WatchTransferState {
        offlineManager.storageInfo(for: book.book.id).state
    }

    private var chapterInfos: [WatchChapterStorageInfo] {
        offlineManager.chapterStorageInfo(for: book)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch state {
                case .notAvailable:
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("Not Downloaded")
                            .font(.headline)
                            .accessibilityIdentifier(WatchAccessibilityID.fetchOverallState)
                    }
                case .queued:
                    VStack(spacing: 4) {
                        ProgressView()
                        Text("Fetching...")
                            .font(.caption)
                            .accessibilityIdentifier(WatchAccessibilityID.fetchOverallState)
                    }
                case .waitingForPhone:
                    VStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("Phone Required")
                            .font(.headline)
                            .accessibilityIdentifier(WatchAccessibilityID.fetchOverallState)
                        Text("Your iPhone is needed to complete this download. Make sure it's nearby and unlocked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                case .transferring(let p):
                    VStack(spacing: 4) {
                        ProgressView(value: p)
                            .tint(.accentColor)
                        Text("\(Int(p * 100))%")
                            .font(.caption)
                            .accessibilityIdentifier(WatchAccessibilityID.fetchOverallState)
                    }
                case .available:
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("Ready")
                            .font(.headline)
                            .accessibilityIdentifier(WatchAccessibilityID.fetchOverallState)
                    }
                case .failed:
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                        Text("Download Failed")
                            .font(.headline)
                            .accessibilityIdentifier(WatchAccessibilityID.fetchOverallState)
                        Text("The download could not be completed. Check your connection and try again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chapterInfos) { chapter in
                        HStack(spacing: 8) {
                            Text("Ch \(chapter.chapterIndex + 1)")
                                .font(.caption2.monospacedDigit())
                            Spacer(minLength: 4)
                            if let progress = chapter.state.progressFraction {
                                ProgressView(value: progress)
                                    .frame(width: 32)
                            }
                            Text(chapterStateText(chapter.state))
                                .font(.caption2)
                                .foregroundStyle(chapterStateColor(chapter.state))
                                .lineLimit(1)
                                .accessibilityIdentifier(WatchAccessibilityID.fetchChapterState(chapter.chapterIndex + 1))
                        }
                    }
                }

                // Action buttons
                HStack(spacing: 12) {
                    if state == .notAvailable {
                        Button("Download") {
                            Task {
                                await services.downloadBook(book)
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.bookFetch)
                    }

                    if state == .failed || state == .waitingForPhone {
                        Button("Retry") {
                            Task {
                                await services.downloadBook(book)
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.fetchRetry)
                    }

                    if state == .queued || isTransferring(state) {
                        Button("Cancel") {
                            Task {
                                await offlineManager.deleteOffline(bookID: book.book.id)
                                dismiss()
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.fetchCancel)
                    }
                }
                .padding(.top, 4)
            }
            .padding()
            .frame(minHeight: 88)
        }
        .accessibilityIdentifier(WatchAccessibilityID.fetchStatus)
    }

    private func isTransferring(_ state: WatchTransferState) -> Bool {
        if case .transferring = state { return true }
        return false
    }

    private func chapterStateText(_ state: WatchTransferState) -> String {
        switch state {
        case .notAvailable:
            return "Not downloaded"
        case .queued:
            return "Queued"
        case .waitingForPhone:
            return "Waiting"
        case .transferring:
            return "Downloading"
        case .available:
            return "Downloaded"
        case .failed:
            return "Failed"
        }
    }

    private func chapterStateColor(_ state: WatchTransferState) -> Color {
        switch state {
        case .available:
            return .green
        case .failed:
            return .red
        case .waitingForPhone:
            return .orange
        default:
            return .secondary
        }
    }
}
