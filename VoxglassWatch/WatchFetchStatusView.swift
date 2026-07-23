import SwiftUI
import VoxglassCore

struct WatchFetchStatusView: View {
    let book: BookWithChapters
    @EnvironmentObject var services: WatchAppServices
    @Environment(\.dismiss) private var dismiss

    private var state: WatchTransferState {
        services.offlineManager.storageInfo(for: book.book.id).state
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switch state {
                case .notAvailable:
                    EmptyView()
                case .queued:
                    VStack(spacing: 4) {
                        ProgressView()
                        Text("Fetching...")
                            .font(.caption)
                    }
                case .waitingForPhone:
                    VStack(spacing: 6) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("Phone Required")
                            .font(.headline)
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
                    }
                case .available:
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("Ready")
                            .font(.headline)
                    }
                case .failed:
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                        Text("Download Failed")
                            .font(.headline)
                        Text("The download could not be completed. Check your connection and try again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                }

                // Action buttons
                HStack(spacing: 12) {
                    if state == .failed || state == .waitingForPhone {
                        Button("Retry") {
                            Task {
                                // Retry download
                            }
                        }
                        .accessibilityIdentifier(WatchAccessibilityID.fetchRetry)
                    }

                    if state == .queued || isTransferring(state) {
                        Button("Cancel") {
                            Task {
                                await services.offlineManager.deleteOffline(bookID: book.book.id)
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
}
