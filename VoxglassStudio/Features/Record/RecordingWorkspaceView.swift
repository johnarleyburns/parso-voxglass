import SwiftUI
import VoxglassCore

public struct RecordingWorkspaceView: View {
    let model: RecordingModel
    let paragraph: Paragraph?
    let paragraphIndex: Int
    let totalParagraphs: Int
    var onAccept: () -> Void = {}
    var onNavigate: (Int) -> Void = { _ in }

    public var body: some View {
        VStack(spacing: 0) {
            teleprompterSection
            meterSection
            recordingControls
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            Task { await model.prepare() }
        }
    }

    private var teleprompterSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let paragraph {
                    Text(paragraph.text)
                        .font(.system(size: 28, weight: .medium))
                        .lineSpacing(8)
                        .padding(.horizontal, 80)
                        .padding(.vertical, 60)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("record.teleprompter")
                        #if DEBUG
                        .countRenders("record.teleprompter")
                        #endif
                } else {
                    Text("No paragraph selected")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("record.noParagraph")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var meterSection: some View {
        // The meter is isolated in its own view so its ~30 Hz updates never
        // invalidate the teleprompter (spec §11.3). The parent body must not
        // read any meter property directly.
        MeterSectionView(meter: model.meter)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .accessibilityIdentifier("record.meters")
    }

    private var recordingControls: some View {
        HStack(spacing: 20) {
            Button(action: { Task { await model.startMonitoring() } }) {
                Image(systemName: "headphones")
            }
            .help("Monitor")
            .accessibilityIdentifier("record.monitor")

            Button(action: {
                Task {
                    if model.canRecord {
                        await model.startRecording(paragraphID: paragraph?.id ?? UUID())
                    } else {
                        await model.stopRecording()
                    }
                }
            }) {
                Image(systemName: model.canRecord ? "record.circle" : "stop.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(model.canRecord ? .red : .primary)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Record / Stop")
            .accessibilityIdentifier("record.transport")

            NavigationButtons(
                index: paragraphIndex,
                total: totalParagraphs,
                onPrevious: { onNavigate(paragraphIndex - 1) },
                onNext: { onNavigate(paragraphIndex + 1) }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .accessibilityIdentifier("record.controls")
    }

    public init(model: RecordingModel, paragraph: Paragraph?, paragraphIndex: Int, totalParagraphs: Int, onAccept: @escaping () -> Void = {}, onNavigate: @escaping (Int) -> Void = { _ in }) {
        self.model = model
        self.paragraph = paragraph
        self.paragraphIndex = paragraphIndex
        self.totalParagraphs = totalParagraphs
        self.onAccept = onAccept
        self.onNavigate = onNavigate
    }
}

/// Isolated meter: reads the `@Observable` meter properties only inside its own
/// body, so its ~30 Hz updates never invalidate the parent workspace
/// (spec §11.3).
private struct MeterSectionView: View {
    let meter: RecordingMeter

    var body: some View {
        HStack(spacing: 16) {
            meterBar(label: "Peak", value: meter.peakDBFS, color: .orange)
            meterBar(label: "RMS", value: meter.rmsDBFS, color: .green)
        }
        #if DEBUG
        .countRenders("record.meter")
        #endif
    }

    private func meterBar(label: String, value: Float, color: Color) -> some View {
        let normalized = max(0, (value + 60) / 60)
        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(normalized))
                }
            }
            .frame(height: 8)

            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f dB", value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("record.meter.\(label.lowercased())")
    }
}

struct NavigationButtons: View {
    let index: Int
    let total: Int
    var onPrevious: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
            }
            .disabled(index <= 0)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .accessibilityIdentifier("record.previousParagraph")

            Text("\(index + 1) / \(total)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("record.paragraphCounter")

            Button(action: onNext) {
                Image(systemName: "chevron.right")
            }
            .disabled(index >= total - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityIdentifier("record.nextParagraph")
        }
    }
}
