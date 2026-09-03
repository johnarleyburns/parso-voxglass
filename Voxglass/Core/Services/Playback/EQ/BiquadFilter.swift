import Foundation
import ParsoAudioPlayback

/// The 10-band graphic EQ is now shared: `parso-audio-engine`'s `GraphicEQ`
/// (`ParsoAudioPlayback`) is the RBJ peaking cascade both apps grew independently
/// (parso-audio-engine/docs/UNIFICATION_PLAN.md §3). This `EQEngine` keeps
/// Voxglass's class shape — an EQ cascade followed by the realtime RMS
/// `VolumeNormalizer` — so `EQAudioProcessor` and its tap plumbing are
/// untouched. Voxglass drives the cascade at Q 1.0 (`GraphicEQ` defaults to
/// Tonearm's 1.41), passed explicitly so the EQ sound does not change.
public final class EQEngine {
    /// ISO 10-band centers (Hz). `GraphicEQ` works in `Double`; Voxglass's UI and
    /// stores are `Float`, so this stays `[Float]`.
    public static let isoBands: [Float] = GraphicEQ.isoBandFrequencies.map(Float.init)
    public static let defaultQ: Float = 1.0
    public static let sampleRate: Float = 44_100

    private var eq: GraphicEQ
    public var gains: [Float] { didSet { rebuild() } }
    public let normalizer = VolumeNormalizer()
    public var eqStagesEnabled = true

    public init(gains: [Float] = Array(repeating: 0, count: 10), eqStagesEnabled: Bool = true) {
        self.gains = gains
        self.eqStagesEnabled = eqStagesEnabled
        self.eq = GraphicEQ(sampleRate: Double(Self.sampleRate),
                            q: Double(Self.defaultQ),
                            gains: gains.map(Double.init))
    }

    public var isFlat: Bool { gains.allSatisfy { $0 == 0 } }
    public var isBypassed: Bool { eq.isTransparent }

    public func setGain(_ gain: Float, at band: Int) {
        guard band >= 0, band < gains.count else { return }
        gains[band] = gain   // didSet rebuilds
    }

    /// Rebuilds the cascade from `gains` (kept for call-site compatibility;
    /// `gains`/`setGain` already rebuild).
    public func reconfigure() { rebuild() }

    private func rebuild() {
        eq.setGains(gains.map(Double.init))
    }

    public func process(_ input: Float) -> Float {
        var sample = input
        if eqStagesEnabled {
            sample = eq.process(sample, channel: 0)
        }
        return normalizer.process(sample)
    }

    public func reset() {
        eq.reset()
        normalizer.reset()
    }

    public func copy() -> EQEngine {
        EQEngine(gains: gains, eqStagesEnabled: eqStagesEnabled)
    }
}

public struct EQPreset: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var gains: [Float]
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, gains: [Float], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.gains = gains
        self.isBuiltIn = isBuiltIn
    }

    public static let flat = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!,
        name: "Flat",
        gains: Array(repeating: 0, count: 10),
        isBuiltIn: true
    )

    public static let concertHall = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!,
        name: "Concert Hall",
        gains: [3, 2, 1, 0, 0, 0, 1, 2, 3, 4],
        isBuiltIn: true
    )

    public static let spokenWord = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!,
        name: "Spoken Word",
        gains: [-3, -2, 0, 2, 3, 4, 3, 0, -1, -2],
        isBuiltIn: true
    )

    public static let rpm78 = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000004")!,
        name: "78 rpm",
        gains: [0, 0, -2, -4, -2, 1, 3, 2, 0, -1],
        isBuiltIn: true
    )

    public static let builtInPresets: [EQPreset] = [.flat, .concertHall, .spokenWord, .rpm78]
}
