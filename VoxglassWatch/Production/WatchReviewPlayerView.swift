import SwiftUI
import VoxglassCore

/// Review player (mockup 04): paragraph transport + Flag/Approve/Pickup. Crown stays
/// volume; paragraph movement is by ◀¶/¶▶ and swipe. Flag is the most prominent
/// action. Long-press opens the tag/dictation picker; the header opens the paragraph
/// text screen.
struct WatchReviewPlayerView: View {
    @Environment(ProductionWatchEnvironment.self) private var env

    var body: some View {
        if let review = env.review {
            content(review)
                .sheet(isPresented: confirmationBinding(review)) {
                    WatchReviewConfirmationView(review: review)
                }
        } else {
            VStack(spacing: 6) {
                Text("No active review queue.")
                    .foregroundStyle(.secondary)
                Button("Start Review") {
                    env.startFlaggedReview()
                }
            }
            .task {
                if env.review == nil, env.activeQueue != nil {
                    env.startFlaggedReview()
                }
            }
        }
    }

    private func content(_ review: WatchReviewModel) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                NavigationLink(value: ProductionRoute.paragraphText) {
                    VStack(spacing: 2) {
                        Text("\(review.payload.queueLabel) \(review.positionLabel)")
                            .font(.headline)
                        Text(review.currentChapterLabel ?? "Paragraph")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                WaveformPlaceholder()
                    .frame(height: 36)

                HStack(spacing: 16) {
                    Button {
                        Task { await review.previous() }
                    } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.title3)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerPrevious)
                    .contentShape(Rectangle())

                    Button {
                        Task { await playPause(review) }
                    } label: {
                        Image(systemName: env.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 40))
                    }
                    .contentShape(Rectangle())

                    Button {
                        Task { await review.next() }
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.title3)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerNext)
                    .contentShape(Rectangle())
                }
                .padding(.vertical, 2)

                HStack(spacing: 8) {
                    Button {
                        Task { await review.flag() }
                    } label: {
                        actionLabel("Flag", systemImage: "flag.fill", primary: true)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerFlag)
                    .contentShape(Rectangle())

                    Button {
                        Task { await review.approve() }
                    } label: {
                        actionLabel("Approve", systemImage: "checkmark", primary: false)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerApprove)
                    .contentShape(Rectangle())

                    Button {
                        Task { await review.needsPickup() }
                    } label: {
                        actionLabel("Pickup", systemImage: "arrow.triangle.2.circlepath", primary: false)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerPickup)
                    .contentShape(Rectangle())
                }

                Toggle("Auto-next", isOn: autoNextBinding(review))
                    .accessibilityIdentifier(ProductionWatchAccessibility.playerAutoNext)
                    .contentShape(Rectangle())
                    .padding(.top, 4)

                if !review.isAudioAvailable {
                    Text("Audio not downloaded — open Voxglass on iPhone")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.yellow)
                }
            }
            .padding()
        }
        .navigationTitle("Review")
        .contextMenu {
            NavigationLink(value: ProductionRoute.dictation) {
                Label("Add Note", systemImage: "mic.fill")
            }
        }
    }

    private func playPause(_ review: WatchReviewModel) async {
        if env.player.isPlaying {
            env.player.pause()
        } else {
            await review.playCurrent()
        }
    }

    private func actionLabel(_ title: String, systemImage: String, primary: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(primary ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(primary ? .white : .primary)
    }

    private func confirmationBinding(_ review: WatchReviewModel) -> Binding<Bool> {
        Binding(
            get: { review.confirmation != nil },
            set: { if !$0 { review.dismissConfirmation() } }
        )
    }

    private func autoNextBinding(_ review: WatchReviewModel) -> Binding<Bool> {
        Binding(
            get: { review.autoAdvance },
            set: { review.autoAdvance = $0 }
        )
    }
}

struct WaveformPlaceholder: View {
    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<48, id: \.self) { index in
                    let height = CGFloat(6 + (index % 7) * 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.blue.opacity(0.7))
                        .frame(width: 2, height: height)
                        .frame(maxHeight: geometry.size.height, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
