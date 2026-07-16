import Foundation

/// Stores the user's own EQ presets (JSON in UserDefaults). Built-in presets are
/// always present via `EQPreset.builtInPresets`; `all` combines both.
public final class EQPresetStore {
    private let defaults: UserDefaults
    private let key = "voxglass.eq.userPresets"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func savedPresets() -> [EQPreset] {
        guard let data = defaults.data(forKey: key),
              let presets = try? JSONDecoder().decode([EQPreset].self, from: data) else {
            return []
        }
        return presets
    }

    public var all: [EQPreset] {
        EQPreset.builtInPresets + savedPresets()
    }

    public func save(_ preset: EQPreset) {
        var preset = preset
        preset.isBuiltIn = false
        var presets = savedPresets()
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist(presets)
    }

    public func delete(_ id: UUID) {
        persist(savedPresets().filter { $0.id != id })
    }

    private func persist(_ presets: [EQPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }
}
