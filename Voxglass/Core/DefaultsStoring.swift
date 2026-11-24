import VoxglassPortable

/// Compatibility aliases so `VoxglassCore` call sites and tests can use the
/// portable defaults seam without each file importing `VoxglassPortable`.
/// Mirrors the existing `ImportedTitle` re-export pattern.
public typealias DefaultsStoring = VoxglassPortable.DefaultsStoring
public typealias SendableDefaultsStoring = VoxglassPortable.SendableDefaultsStoring
public typealias InMemoryDefaultsStore = VoxglassPortable.InMemoryDefaultsStore
