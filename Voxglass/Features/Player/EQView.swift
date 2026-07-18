import SwiftUI
import VoxglassCore

struct EQView: View {
    @ObservedObject private var storeManager = StoreManager.shared
    @EnvironmentObject private var playback: PlaybackCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var gains: [Float] = Array(repeating: 0, count: 10)
    @State private var isEngaged = false
    @State private var presets: [EQPreset] = EQPreset.builtInPresets
    @State private var selectedPresetID: UUID?
    @State private var showSavePrompt = false
    @State private var newPresetName = ""
    @State private var showPaywall = false

    private var bandLabels: [String] {
        EQEngine.isoBands.map { hz in
            hz >= 1000
                ? "\(Int(hz / 1000))k"
                : "\(Int(hz))"
        }
    }

    var body: some View {
        ZStack {
            VoxglassTheme.warmBackground.ignoresSafeArea()
            if ProFeature.isEnabled(.eq) {
                content
            } else {
                lockedTeaser
            }
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Palette.ink2)
            }
        }
        .paywallSheet(isPresented: $showPaywall)
        .onAppear(perform: loadState)
        .alert("Save Preset", isPresented: $showSavePrompt) {
            TextField("Preset name", text: $newPresetName)
            Button("Save", action: savePreset)
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Save the current band gains as your own preset.")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                engageToggle
                presetPicker
                bandSliders
                saveButton
            }
            .padding(18)
        }
    }

    private var engageToggle: some View {
        Toggle(isOn: Binding(
            get: { isEngaged },
            set: { engaged in
                isEngaged = engaged
                playback.setEQEngaged(engaged)
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Equalizer")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Palette.ink)
                Text("Apply the 10-band equalizer to playback.")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
            }
        }
        .tint(Palette.brass)
        .accessibilityIdentifier("eq.engage")
        .padding(15)
        .glassSurface(cornerRadius: 16)
    }

    private var presetPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Presets")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        FilterChip(
                            title: preset.name,
                            systemImage: preset.isBuiltIn ? nil : "person.fill",
                            isSelected: selectedPresetID == preset.id
                        ) {
                            apply(preset)
                        }
                        .contextMenu {
                            if !preset.isBuiltIn {
                                Button("Delete", role: .destructive) { delete(preset) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 1)
            }
        }
    }

    private var bandSliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Bands")
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(gains.indices, id: \.self) { band in
                    bandSlider(band)
                }
            }
            .frame(height: 220)
            .padding(15)
            .glassSurface(cornerRadius: 16)
        }
    }

    private func bandSlider(_ band: Int) -> some View {
        VStack(spacing: 6) {
            Text(gainLabel(gains[band]))
                .scaledFont(size: 9, design: .monospaced)
                .foregroundStyle(Palette.ink3)
            Slider(
                value: Binding(
                    get: { Double(gains[band]) },
                    set: { newValue in
                        gains[band] = Float(newValue)
                        selectedPresetID = nil
                        playback.setEQGain(Float(newValue), at: band)
                    }
                ),
                in: -12...12,
                step: 1
            )
            .rotationEffect(.degrees(-90))
            .frame(width: 150, height: 28)
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("eq.band.\(band)")
            Text(bandLabels[band])
                .scaledFont(size: 9, weight: .semibold)
                .foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity)
    }

    private var saveButton: some View {
        Button {
            newPresetName = ""
            showSavePrompt = true
        } label: {
            Label("Save as Preset", systemImage: "plus.circle.fill")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(Palette.brass)
        }
        .buttonStyle(.plain)
    }

    private var lockedTeaser: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .scaledFont(size: 44)
                .foregroundStyle(Palette.brass)
            Text("10-Band Equalizer")
                .scaledFont(size: 20, weight: .bold)
                .foregroundStyle(Palette.ink)
            Text("Shape playback with presets for Concert Hall, Spoken Word, 78 rpm — and your own. A Voxglass Pro feature.")
                .scaledFont(size: 13)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button {
                showPaywall = true
            } label: {
                Text("Unlock Pro")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(Color(hex: 0x221503))
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .background(Palette.brass, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pro.lock.eq")
        }
        .padding(24)
    }

    private func gainLabel(_ gain: Float) -> String {
        let value = Int(gain.rounded())
        return value > 0 ? "+\(value)" : "\(value)"
    }

    private func loadState() {
        presets = playback.eqPresets.all
        gains = playback.eqGains
        isEngaged = playback.isEQEngaged
        selectedPresetID = presets.first { $0.gains == gains }?.id
    }

    private func apply(_ preset: EQPreset) {
        gains = preset.gains
        selectedPresetID = preset.id
        playback.applyEQPreset(preset)
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPresetName = ""
        guard !name.isEmpty else { return }
        let preset = EQPreset(name: name, gains: gains)
        playback.eqPresets.save(preset)
        presets = playback.eqPresets.all
        selectedPresetID = preset.id
    }

    private func delete(_ preset: EQPreset) {
        playback.eqPresets.delete(preset.id)
        presets = playback.eqPresets.all
        if selectedPresetID == preset.id {
            selectedPresetID = nil
        }
    }
}
