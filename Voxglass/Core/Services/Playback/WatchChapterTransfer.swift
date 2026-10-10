import Foundation
import AVFoundation
import VoxglassWatchCore
import ParsoAudioStreaming
import os

/// Resolves the on-phone blob for a phone→watch chapter transfer. Extracted so
/// the phone relay and host tests share one implementation: a chapter is
/// transferable only when its blob is complete in the store, and the resolved
/// URL must come from the store — never from a hand-built path (RC2). Never
/// touches the network.
public enum WatchChapterTransfer {
    // AVFoundation's synchronous decoder may block while waiting for its codec
    // workers. Never occupy Swift's bounded cooperative pool with that wait.
    private static let conversionQueue = DispatchQueue(label: "guru.parso.voxglass.watch-aac", qos: .userInitiated, attributes: .concurrent)
    /// The watch-only listening profile. Phone originals and narration masters are untouched.
    public static let watchBitRate = 96_000

    /// Prepare a complete, chapter-bounded AAC file before submitting it to Apple.
    /// Shared-file M4B chapters are extracted once per chapter; the caller may memoize source hashes.
    public static func prepareAAC(source: URL, directory: URL, startTime: Double = 0,
                                  duration: Double? = nil, sourceHash: String? = nil,
                                  mimeType: String? = nil) async throws -> URL {
        try Task.checkCancellation()
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, startTime.isFinite, startTime >= 0,
              duration == nil || (duration?.isFinite == true && (duration ?? 0) > 0) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let digest = try sourceHash ?? WatchChecksum.sha256(of: source)
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else { throw CocoaError(.fileReadCorruptFile) }
        let name = "\(digest)-watch-aac96-\(Int64(startTime * 1000))-\(Int64((duration ?? 0) * 1000)).m4a"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            if let audio = try? AVAudioFile(forReading: destination), audio.length > 0,
               audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC { return destination }
            // Only this disposable derived file is replaced; never the source/master.
            try FileManager.default.removeItem(at: destination)
        }
        let temporary = destination.appendingPathExtension("preparing")
        if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let asset = AVURLAsset(url: source, options: mimeType.map { [AVURLAssetOverrideMIMETypeKey: $0] })
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
        let assetDuration = try await asset.load(.duration).seconds
        let length = min(duration ?? (assetDuration - startTime), assetDuration - startTime)
        guard length.isFinite, length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let reader = try AVAssetReader(asset: asset)
        let start = CMTime(seconds: startTime, preferredTimescale: 44_100)
        reader.timeRange = CMTimeRange(start: start, duration: CMTime(seconds: length, preferredTimescale: 44_100))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: watchBitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? CocoaError(.fileReadCorruptFile)
        }
        writer.startSession(atSourceTime: start)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let pipeline = WatchAACPipeline(reader: reader, output: output, writer: writer, input: input)
        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    conversionQueue.async {
                        do {
                            try pipeline.consume(cancelled: cancelled)
                            continuation.resume()
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
            try Task.checkCancellation()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }
    /// Returns the complete blob's URL for `chapterKey`, or nil when the blob is
    /// absent or incomplete.
    public static func resolvedFileURL(cacheStore: SparseCacheStore, chapterKey: String) async -> URL? {
        guard await cacheStore.isComplete(chapterKey) else { return nil }
        let url = await cacheStore.fileURL(for: chapterKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// AVFoundation handles are constructed before submission, then exclusively consumed
/// by one dispatch-queue invocation. The caller does not touch them until that
/// invocation resumes its continuation. Cancellation shares only a locked flag,
/// never the non-Sendable reader/writer handles themselves.
private struct WatchAACPipeline: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput

    func consume(cancelled: OSAllocatedUnfairLock<Bool>) throws {
        while true {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
            let finished = try autoreleasepool { () throws -> Bool in
                guard let buffer = output.copyNextSampleBuffer() else { return true }
                while !input.isReadyForMoreMediaData {
                    if cancelled.withLock({ $0 }) { throw CancellationError() }
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                guard input.append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                return false
            }
            if finished { break }
        }
        guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        input.markAsFinished()
    }
}
