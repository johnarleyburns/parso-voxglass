import Foundation

public protocol AudioDecoding: Sendable {
    func describe(_ url: URL) async throws -> AudioFormatDescription
    func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio
}

public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: TimeInterval

    public init(samples: [Float], sampleRate: Double, duration: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
    }
}
