import Foundation
import AVFoundation
import VoxglassCore

/// Generates the AAC mono `.m4a` review proxies that get published to CloudKit
/// (spec §13.4). Uses `AVAssetExportSession`'s Apple M4A preset so no third-party
/// encoder is needed. Bitrate control is preset-determined; the requested
/// `proxyBitrateKbps` is recorded in the projection for the storage estimate.
public struct ProxyGenerator: Sendable {

    public init() {}

    /// Exports `source` (a take's trimmed WAV) to a mono AAC `.m4a` at `output`.
    public func generate(from source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ProxyError.unableToCreateSession
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        export.outputURL = output
        export.outputFileType = .m4a
        export.shouldOptimizeForNetworkUse = false
        let trimmed = try await asset.load(.duration).seconds
        export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: trimmed, preferredTimescale: 600))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }
        guard export.status == .completed, export.error == nil else {
            throw ProxyError.exportFailed(export.error?.localizedDescription ?? "unknown")
        }
    }

    public enum ProxyError: Error {
        case unableToCreateSession
        case exportFailed(String)
    }
}
