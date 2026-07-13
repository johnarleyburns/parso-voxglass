import Foundation

struct BiquadFilter {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    mutating func reset() {
        x1 = 0; x2 = 0; y1 = 0; y2 = 0
    }

    mutating func configurePeakingEQ(frequency: Float, sampleRate: Float, gainDB: Float, q: Float) {
        let omega = 2 * Float.pi * frequency / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let A = pow(10, gainDB / 40)
        let alpha = sn / (2 * q)

        let b0tmp =  1 + alpha * A
        let b1tmp = -2 * cs
        let b2tmp =  1 - alpha * A
        let a0tmp =  1 + alpha / A
        let a1tmp = -2 * cs
        let a2tmp =  1 - alpha / A

        let a0Inv = 1 / a0tmp
        b0 = b0tmp * a0Inv
        b1 = b1tmp * a0Inv
        b2 = b2tmp * a0Inv
        a1 = a1tmp * a0Inv
        a2 = a2tmp * a0Inv
    }

    mutating func configureLowShelf(frequency: Float, sampleRate: Float, gainDB: Float, q: Float = 0.707) {
        let omega = 2 * Float.pi * frequency / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let A = pow(10, gainDB / 40)
        let beta = sqrt(A) / q

        let b0tmp = A * ((A + 1) - (A - 1) * cs + beta * sn)
        let b1tmp = 2 * A * ((A - 1) - (A + 1) * cs)
        let b2tmp = A * ((A + 1) - (A - 1) * cs - beta * sn)
        let a0tmp = (A + 1) + (A - 1) * cs + beta * sn
        let a1tmp = -2 * ((A - 1) + (A + 1) * cs)
        let a2tmp = (A + 1) + (A - 1) * cs - beta * sn

        let a0Inv = 1 / a0tmp
        b0 = b0tmp * a0Inv
        b1 = b1tmp * a0Inv
        b2 = b2tmp * a0Inv
        a1 = a1tmp * a0Inv
        a2 = a2tmp * a0Inv
    }

    mutating func configureHighShelf(frequency: Float, sampleRate: Float, gainDB: Float, q: Float = 0.707) {
        let omega = 2 * Float.pi * frequency / sampleRate
        let sn = sin(omega)
        let cs = cos(omega)
        let A = pow(10, gainDB / 40)
        let beta = sqrt(A) / q

        let b0tmp = A * ((A + 1) + (A - 1) * cs + beta * sn)
        let b1tmp = -2 * A * ((A - 1) + (A + 1) * cs)
        let b2tmp = A * ((A + 1) + (A - 1) * cs - beta * sn)
        let a0tmp = (A + 1) - (A - 1) * cs + beta * sn
        let a1tmp = 2 * ((A - 1) - (A + 1) * cs)
        let a2tmp = (A + 1) - (A - 1) * cs - beta * sn

        let a0Inv = 1 / a0tmp
        b0 = b0tmp * a0Inv
        b1 = b1tmp * a0Inv
        b2 = b2tmp * a0Inv
        a1 = a1tmp * a0Inv
        a2 = a2tmp * a0Inv
    }

    var isBypassed: Bool {
        b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0
    }
}

final class EQEngine {
    static let isoBands: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let defaultQ: Float = 1.0
    static let sampleRate: Float = 44100

    private var filters: [BiquadFilter]
    var gains: [Float]
    let normalizer = VolumeNormalizer()
    var eqStagesEnabled = true

    init(gains: [Float] = Array(repeating: 0, count: 10), eqStagesEnabled: Bool = true) {
        self.gains = gains
        self.filters = Array(repeating: BiquadFilter(), count: 10)
        self.eqStagesEnabled = eqStagesEnabled
        reconfigure()
    }

    var isFlat: Bool {
        gains.allSatisfy { $0 == 0 }
    }

    var isBypassed: Bool {
        filters.allSatisfy { $0.isBypassed }
    }

    func setGain(_ gain: Float, at band: Int) {
        guard band >= 0, band < gains.count else { return }
        gains[band] = gain
        filters[band].configurePeakingEQ(
            frequency: Self.isoBands[band],
            sampleRate: Self.sampleRate,
            gainDB: gain,
            q: Self.defaultQ
        )
    }

    func reconfigure() {
        for (i, gain) in gains.enumerated() {
            filters[i].configurePeakingEQ(
                frequency: Self.isoBands[i],
                sampleRate: Self.sampleRate,
                gainDB: gain,
                q: Self.defaultQ
            )
        }
    }

    func process(_ input: Float) -> Float {
        var sample = input
        if eqStagesEnabled {
            for i in 0..<filters.count {
                sample = filters[i].process(sample)
            }
        }

        return normalizer.process(sample)
    }

    func reset() {
        for i in 0..<filters.count {
            filters[i].reset()
        }
        normalizer.reset()
    }

    func copy() -> EQEngine {
        let copy = EQEngine(gains: gains)
        return copy
    }
}

struct EQPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var gains: [Float]
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, gains: [Float], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.gains = gains
        self.isBuiltIn = isBuiltIn
    }

    static let flat = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!,
        name: "Flat",
        gains: Array(repeating: 0, count: 10),
        isBuiltIn: true
    )

    static let concertHall = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!,
        name: "Concert Hall",
        gains: [3, 2, 1, 0, 0, 0, 1, 2, 3, 4],
        isBuiltIn: true
    )

    static let spokenWord = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!,
        name: "Spoken Word",
        gains: [-3, -2, 0, 2, 3, 4, 3, 0, -1, -2],
        isBuiltIn: true
    )

    static let rpm78 = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000004")!,
        name: "78 rpm",
        gains: [0, 0, -2, -4, -2, 1, 3, 2, 0, -1],
        isBuiltIn: true
    )

    static let builtInPresets: [EQPreset] = [.flat, .concertHall, .spokenWord, .rpm78]
}
