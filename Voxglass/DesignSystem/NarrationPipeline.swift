import SwiftUI
import VoxglassCore

struct PipelineBar: View {
    let phase: NarrationPhase
    var body: some View {
        let current: Int = {
            switch phase { case .draft, .recording: 0; case .review: 1; case .package: 2; case .ready: 3 }
        }()
        HStack(spacing: 4) {
            ForEach(Array(["Record", "Review", "Package", "Hand off"].enumerated()), id: \.offset) { index, label in
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(index < current ? NarrationPalette.mint : (index == current ? Palette.brass : Color.white.opacity(0.12))).frame(height: 4)
                    Text(label).voxType(.eyebrow).foregroundStyle(index <= current ? Palette.ink2 : Palette.ink3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of 4, \(phase.label)")
        .accessibilityIdentifier("narration.pipeline")
    }
}

struct ProgressRingButton: View {
    let title: String
    let progress: Double
    let isPlaying: Bool
    let isFinished: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 2.4)
                Circle().trim(from: 0, to: min(max(progress, 0), 1)).stroke(isFinished ? NarrationPalette.mint : Palette.brass, style: StrokeStyle(lineWidth: 2.4, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: isFinished ? "checkmark" : (isPlaying ? "pause.fill" : "play.fill"))
                    .scaledFont(size: 11, weight: .semibold)
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(title), \(Int(progress * 100)) percent")
    }
}
