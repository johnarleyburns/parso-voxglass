import SwiftUI
import VoxglassCore

/// Watch recording remote (mockup watch-04, §14.3) — the only new watch surface
/// in this MVP. Shows the paragraph and chapter the iPhone is recording, a live
/// level meter, elapsed take time, and the five commands (record/stop, retake,
/// flag, accept & next). Commands are idempotent by `(sessionID, sequence)`, so a
/// duplicated transfer can never make a second take. No audio crosses the link.
struct WatchRecordingRemoteView: View {
    @Environment(ProductionWatchEnvironment.self) private var env
    @State private var model: WatchRecordingRemoteModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let model {
                    contextCard(model)
                    levelMeter(model)
                    transport(model)
                    actionRow(model)

                    if !model.hasLiveSession {
                        idleCard
                    }

                    if let error = model.error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .multilineTextAlignment(.center)
                    }

                    Text("Recording happens on iPhone. Your watch only sends the command.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        }
        .navigationTitle("Remote")
        .task {
            if model == nil {
                model = WatchRecordingRemoteModel(environment: env)
            }
            await model?.start()
        }
    }

    private func contextCard(_ model: WatchRecordingRemoteModel) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(model.status.map { "¶ \($0.paragraphNumber)" } ?? "¶ —")
                    .font(.headline)
                Spacer()
                if let status = model.status, status.isRecording {
                    Text(model.elapsedLabel)
                        .font(.footnote.monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.25), in: Capsule())
                        .foregroundStyle(.red)
                }
            }
            Text(model.status?.chapterTitle ?? "Chapter")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(ProductionWatchAccessibility.remoteContext)
    }

    private func levelMeter(_ model: WatchRecordingRemoteModel) -> some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                let bars = Array(repeating: 0, count: 16)
                ForEach(Array(bars.enumerated()), id: \.offset) { bar, _ in
                    let fraction = levelFraction(for: bar)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(levelColor(bar))
                        .frame(width: 3, height: max(3, geometry.size.height * fraction))
                        .frame(maxHeight: geometry.size.height, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 18)
        .accessibilityIdentifier(ProductionWatchAccessibility.remoteLevel)
        .accessibilityLabel(model.status.map { "Input level \(Int($0.levelDBFS)) dB" } ?? "No input level")
    }

    private func levelFraction(for bar: Int) -> CGFloat {
        guard let status = model?.status else { return 0.04 }
        // A live, low-frequency wave over the current level so the meter reads
        // naturally without any animation API (Reduced Motion friendly).
        let db = status.levelDBFS
        let normalised = CGFloat(max(0, min(1, (Double(db) + 60) / 60)))
        let pulse = 0.75 + 0.25 * sin(Double(bar) * 0.9 + elapsedPhase)
        return min(1, normalised * max(0.1, pulse))
    }

    private var elapsedPhase: Double {
        // A slow phase drift so the pulse does not freeze at zero.
        Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3)
    }

    private func levelColor(_ bar: Int) -> Color {
        bar > 12 ? .red : .orange
    }

    private func transport(_ model: WatchRecordingRemoteModel) -> some View {
        HStack(spacing: 14) {
            Button {
                model.playTake()
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.gray.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!model.canPlayTake())
            .accessibilityIdentifier(ProductionWatchAccessibility.remotePlayTake)
            .contentShape(Rectangle())

            Button {
                Task { await model.send(status?.isRecording == true ? .stop : .record) }
            } label: {
                Image(systemName: status?.isRecording == true ? "stop.fill" : "record.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(status?.isRecording == true ? .red : .orange)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        (status?.isRecording == true ? Color.red : Color.orange).opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasLiveSession)
            .accessibilityIdentifier(ProductionWatchAccessibility.remoteRecord)
            .contentShape(Rectangle())

            Button {
                Task { await model.send(.retake) }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.title3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.gray.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!hasLiveSession)
            .accessibilityIdentifier(ProductionWatchAccessibility.remoteRetake)
            .contentShape(Rectangle())
        }
        .padding(.vertical, 4)
    }

    private func actionRow(_ model: WatchRecordingRemoteModel) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.send(.flag) }
            } label: {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!hasLiveSession)
            .accessibilityIdentifier(ProductionWatchAccessibility.remoteFlag)
            .contentShape(Rectangle())

            Button {
                Task { await model.send(.accept) }
            } label: {
                Text("✓ Next")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!hasLiveSession)
            .accessibilityIdentifier(ProductionWatchAccessibility.remoteAcceptAndNext)
            .contentShape(Rectangle())
        }
        .padding(.top, 6)
    }

    private var idleCard: some View {
        VStack(spacing: 2) {
            Text("If iPhone isn't recording")
                .font(.footnote.weight(.semibold))
            Text("\u{201C}iPhone isn't recording.\u{201D} \u{2014} the command is acknowledged and dropped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier(ProductionWatchAccessibility.remoteIdle)
        .opacity(0.8)
    }

    private var status: RecordingRemoteStatus? {
        model?.status
    }

    private var hasLiveSession: Bool {
        model?.hasLiveSession ?? false
    }
}

extension WatchRecordingRemoteModel {
    /// Elapsed take time as m:ss, e.g. "0:07".
    var elapsedLabel: String {
        let seconds = Int(status?.elapsedSeconds ?? 0)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
