import SwiftUI
import VoxglassCore

/// Read-only summary of the export formats available in Voxglass.
struct ExportFormatsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                formatSection("LibriVox") {
                    Text("\(bitrate(DestinationProfile.librivox.audio)) CBR mono MP3, \(sampleRate(DestinationProfile.librivox.audio)), ID3 tags, per-section files")
                }
                formatSection("Personal Listening") {
                    Text("Lossless WAV chapters")
                }

                Section {
                    Text("Every format is free. Voxglass never charges for export.")
                        .font(.footnote)
                        .foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(VoxglassBackground())
            .navigationTitle("Export formats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("formats.sheet")
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func formatSection(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        Section {
            content()
                .font(.body)
                .foregroundStyle(Palette.ink2)
        } header: {
            Text(title)
                .foregroundStyle(Palette.ink)
        }
    }

    private func bitrate(_ spec: AudioSpec) -> String {
        guard let bitrateKbps = spec.bitrateKbps else { return String(localized: "Lossless") }
        return "\(bitrateKbps) kbps"
    }

    private func sampleRate(_ spec: AudioSpec) -> String {
        guard let sampleRate = spec.sampleRate else { return "native sample rate" }
        return "\(Int(sampleRate / 1_000)).1 kHz"
    }
}
