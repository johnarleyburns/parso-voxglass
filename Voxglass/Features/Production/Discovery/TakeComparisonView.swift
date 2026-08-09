import SwiftUI
import VoxglassCore

/// Take comparison sheet (mockup 08, spec §9.5): A/B two takes for one
/// paragraph at matched loudness (ReplayGain values already computed), with
/// per-take metrics and a single "Use this take" action. Selecting a take is a
/// project mutation, so this surface is phone-only.
/// Identifiers: `compare.takeA`, `compare.takeA.play`, `compare.takeA.inContext`,
/// `compare.takeB`, `compare.takeB.play`, `compare.takeB.inContext`,
/// `compare.matchedLoudness`, `compare.useTakeA`, `compare.useTakeB`.
struct TakeComparisonView: View {
    @Bindable var model: NarrationFlowModel
    let paragraphID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let paragraph = model.paragraph(at: paragraphID) {
                        textCard(paragraph)
                    }
                    if let comparison = model.takeComparison(for: paragraphID) {
                        takeCard(comparison.takeA, cardID: "compare.takeA", playID: "compare.takeA.play", inContextID: "compare.takeA.inContext")
                        matchedLoudnessBanner(comparison)
                        takeCard(comparison.takeB, cardID: "compare.takeB", playID: "compare.takeB.play", inContextID: "compare.takeB.inContext")
                        footnote(comparison)
                        footerActions(comparison)
                    } else {
                        Text("Compare two takes to choose one. Record a retake first.")
                            .scaledFont(size: 13)
                            .foregroundStyle(Palette.ink2)
                    }
                }
                .padding(18)
            }
            .background(VoxglassBackground())
            .navigationTitle("Compare takes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("compare.done")
            }
        }
        .presentationDetents([.large])
    }

    private func textCard(_ paragraph: FlowParagraph) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("THE TEXT")
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(Palette.ink3)
            Text(paragraph.text)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
    }

    private func takeCard(_ side: TakeComparison.Side, cardID: String, playID: String, inContextID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(side.label).scaledFont(size: 15, weight: .heavy).foregroundStyle(Palette.ink)
                    Text(subtitle(for: side)).scaledFont(size: 11).foregroundStyle(Palette.ink3)
                }
                Spacer()
                if side.isSelected {
                    Text("Selected")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(NarrationPalette.espresso)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.brass, in: Capsule())
                } else if side.isArchived {
                    Text("Archived")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(Palette.ink2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Palette.ink2.opacity(0.12), in: Capsule())
                }
            }

            kv("Duration", side.duration.formattedShort)
            kv("RMS", dB(side.rmsDBFS), tint: rmsTint(side.rmsDBFS))
            kv("Peak", dB(side.peakDBFS))
            kv("Noise floor", noiseFloor(side.noiseFloorDBFS), tint: noiseFloorTint(side.noiseFloorDBFS))

            HStack(spacing: 10) {
                Button {
                    model.play(side.takeID, in: paragraphID)
                } label: {
                    Label("Play", systemImage: "play")
                        .scaledFont(size: 13, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier(playID)

                Button {
                    model.play(side.takeID, in: paragraphID)
                } label: {
                    Label("In context", systemImage: "text.bubble")
                        .scaledFont(size: 13, weight: .bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Palette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier(inContextID)
            }
        }
        .padding(14)
        .glassSurface(cornerRadius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.hairline, lineWidth: 1))
        .accessibilityIdentifier(cardID)
    }

    private func matchedLoudnessBanner(_ comparison: TakeComparison) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(Palette.brass)
            Text("Matched loudness\(comparison.matchedLoudnessGainDB > 0.05 ? " · +\(String(format: "%.1f", comparison.matchedLoudnessGainDB)) dB applied" : "")")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityIdentifier("compare.matchedLoudness")
    }

    private func footnote(_ comparison: TakeComparison) -> some View {
        Text("Nothing is deleted either way; unselected takes stay in the project.")
            .scaledFont(size: 11.5)
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footerActions(_ comparison: TakeComparison) -> some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    await model.selectTake(comparison.takeB.takeID, for: paragraphID)
                    dismiss()
                }
            } label: {
                Text("Use \(comparison.takeB.label)")
                    .scaledFont(size: 13, weight: .bold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.ink)
            .accessibilityIdentifier("compare.useTakeB")

            Button {
                Task {
                    await model.selectTake(comparison.takeA.takeID, for: paragraphID)
                    dismiss()
                }
            } label: {
                Text(comparison.takeA.isSelected ? "Keep \(comparison.takeA.label)" : "Use \(comparison.takeA.label)")
                    .scaledFont(size: 13, weight: .heavy)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 13))
                    .foregroundStyle(NarrationPalette.espresso)
            }
            .buttonStyle(.plain)
            .tactileTap()
            .accessibilityIdentifier("compare.useTakeA")
        }
        .padding(.top, 4)
    }

    private func subtitle(for side: TakeComparison.Side) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm"
        var parts = [formatter.string(from: side.recordedAt)]
        if let route = side.routeClass {
            parts.append(CaptureRouteClassifier.label(for: route))
        }
        return parts.joined(separator: " · ")
    }

    private func kv(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).scaledFont(size: 12.5).foregroundStyle(Palette.ink2)
            Spacer()
            Text(value)
                .scaledFont(size: 12.5, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(tint ?? Palette.ink)
        }
    }

    private func dB(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f dBFS", value)
    }

    private func noiseFloor(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f dBFS", value)
    }

    /// ACX asks for a noise floor at or below −60 dBFS (§3.4); the retail
    /// profile carries the number, so it is read from the profile, never inlined.
    private var retailNoiseFloorCeiling: Double? {
        DestinationProfile.acx.noiseFloorCeilingDBFS
    }

    private func rmsTint(_ value: Double?) -> Color? {
        guard let value, value.isFinite else { return nil }
        return value < -17 && value > -24 ? Palette.ok : Palette.brass
    }

    private func noiseFloorTint(_ value: Double?) -> Color? {
        guard let value, value.isFinite, let ceiling = retailNoiseFloorCeiling else { return nil }
        return value <= ceiling ? Palette.ok : Palette.danger
    }
}
