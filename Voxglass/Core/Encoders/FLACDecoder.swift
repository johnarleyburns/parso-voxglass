import FLAC
import Foundation
import VoxglassCore

/// libFLAC-backed `SeekableAudioDecoding` for the encoder pipeline (§11.5,
/// §16.3).
///
/// FLAC decode goes through libFLAC's stream decoder on macOS and iPhone;
/// nothing in the FLAC path depends on platform FLAC behavior. The range
/// path positions with `FLAC__stream_decoder_seek_absolute` (via the
/// seek/tell/length/eof callbacks below) so seeking near the end of a
/// multi-hour file decodes only the requested source-frame range plus the
/// bounded lookahead needed for resampling — never the whole file.
///
/// If a stream cannot be positioned, the interactive range path throws
/// `TranscodeError.fileNotSeekable` so the UI can offer a proxy/transcode
/// action instead of silently decoding the whole file (§11.5).
public struct FLACDecoder: SeekableAudioDecoding {

    private var forceNonSeekable: Bool

    public init() {
        self.forceNonSeekable = false
    }

    /// Test seam: makes the seek callback report `UNSUPPORTED` so the
    /// non-seekable error path (§11.5) can be exercised deterministically.
    public init(forceNonSeekable: Bool = false) {
        self.forceNonSeekable = forceNonSeekable
    }

    /// Source samples of resampling lookahead decoded past the requested range
    /// end, so the system SRC never sees a truncated filter window at the tail
    /// of an interactive range decode (§11.5 "bounded lookahead").
    private static let resampleLookaheadFrames = 4096

    // MARK: - AudioDecoding

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        let (source, decoder) = try makeSource(url)
        defer { FLAC__stream_decoder_delete(decoder); try? source.handle.close() }
        try processMetadata(decoder: decoder, source: source, url: url)
        return AudioFormatDescription(
            sampleRate: source.sampleRate,
            channels: source.channels,
            bitDepth: source.bitsPerSample,
            codec: "flac"
        )
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        let (source, decoder) = try makeSource(url)
        defer { FLAC__stream_decoder_delete(decoder); try? source.handle.close() }
        try processMetadata(decoder: decoder, source: source, url: url)

        let rate = source.sampleRate
        let total = source.totalSamples

        guard FLAC__stream_decoder_process_until_end_of_stream(decoder) != 0, source.decodeError == nil else {
            throw TranscodeError.decodeFailed(url)
        }

        let samples = try resampleIfNeeded(source.samples, from: rate, to: targetSampleRate, url: url)
        let duration = total > 0 ? Double(total) / rate : Double(source.samples.count) / rate
        return DecodedAudio(
            samples: samples,
            sampleRate: targetSampleRate ?? rate,
            duration: duration
        )
    }

    // MARK: - SeekableAudioDecoding

    public func decodeToMonoFloat(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> DecodedAudio {
        let result = try decodeRange(url: url, range: range, targetSampleRate: targetSampleRate)
        return result.audio
    }

    /// Range decode plus source-access statistics, so tests can prove the
    /// interactive path is bounded by the requested range rather than by the
    /// total file duration (§19.3 `SeekableFLACDecoderTests`).
    public func decodeRangeWithStats(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> (audio: DecodedAudio, stats: FLACDecodeStats) {
        try decodeRange(url: url, range: range, targetSampleRate: targetSampleRate)
    }

    // MARK: - Shared range/whole-file machinery

    private func decodeRange(
        url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) throws -> (audio: DecodedAudio, stats: FLACDecodeStats) {
        let (source, decoder) = try makeSource(url)
        defer { FLAC__stream_decoder_delete(decoder); try? source.handle.close() }
        try processMetadata(decoder: decoder, source: source, url: url)

        let rate = source.sampleRate
        let total = source.totalSamples

        guard range.startFrame >= 0, range.frameCount >= 0 else {
            throw TranscodeError.decodeFailed(url)
        }

        let start = min(UInt64(max(0, range.startFrame)), total)
        let requested = range.frameCount
        let available = total > start ? Int(total - start) : 0
        let needsResample = targetSampleRate.map { abs($0 - rate) > 0.5 } ?? false
        // Decode the requested range plus a bounded resampling lookahead tail.
        let lookahead = needsResample ? FLACDecoder.resampleLookaheadFrames : 0
        let want = requested <= Int.max - lookahead ? requested + lookahead : Int.max
        let targetCount = available > 0 ? min(want, available) : want

        guard FLAC__stream_decoder_seek_absolute(decoder, start) != 0 else {
            if source.seekUnsupported || source.forceNonSeekable {
                throw TranscodeError.fileNotSeekable(url)
            }
            throw TranscodeError.decodeFailed(url)
        }

        source.samples.reserveCapacity(targetCount)
        while source.samples.count < targetCount && source.decodeError == nil {
            guard FLAC__stream_decoder_process_single(decoder) != 0 else {
                let state = FLAC__stream_decoder_get_state(decoder)
                if state != FLAC__STREAM_DECODER_END_OF_STREAM {
                    throw TranscodeError.decodeFailed(url)
                }
                break
            }
            if FLAC__stream_decoder_get_state(decoder) == FLAC__STREAM_DECODER_END_OF_STREAM {
                break
            }
        }
        if source.decodeError != nil {
            throw TranscodeError.decodeFailed(url)
        }

        var samples = source.samples
        var finalRate = rate
        if needsResample, let targetSampleRate {
            samples = try resampleIfNeeded(samples, from: rate, to: targetSampleRate, url: url)
            finalRate = targetSampleRate
        }
        // Trim the (possibly resampled) output to exactly the requested range.
        let trimmed = needsResample
            ? Array(samples.prefix(Int((Double(requested) * finalRate / rate).rounded(.up))))
            : Array(samples.prefix(min(requested, samples.count)))

        let audio = DecodedAudio(
            samples: trimmed,
            sampleRate: finalRate,
            duration: Double(min(requested, max(0, Int(total) - Int(start)))) / rate
        )
        let stats = FLACDecodeStats(
            bytesReadFromSource: source.bytesRead,
            decodedSourceFrames: source.samples.count
        )
        return (audio, stats)
    }

    private func resampleIfNeeded(
        _ samples: [Float],
        from inputRate: Double,
        to target: Double?,
        url: URL
    ) throws -> [Float] {
        guard let target, abs(target - inputRate) > 0.5 else { return samples }
        do {
            return try AudioResampler.resample(samples, from: inputRate, to: target)
        } catch {
            throw TranscodeError.decodeFailed(url)
        }
    }

    // MARK: - Session setup

    private func makeSource(_ url: URL) throws -> (FLACSource, UnsafeMutablePointer<FLAC__StreamDecoder>) {
        let handle = try FileHandle(forReadingFrom: url)
        let size: UInt64
        do {
            size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            try? handle.close()
            throw TranscodeError.decodeFailed(url)
        }
        let source = FLACSource(handle: handle, size: size, forceNonSeekable: forceNonSeekable)

        guard let decoder = FLAC__stream_decoder_new() else {
            try? handle.close()
            throw TranscodeError.nativeLibrary("FLAC__stream_decoder_new")
        }
        let status = FLAC__stream_decoder_init_stream(
            decoder,
            flacDecoderReadCallback,
            flacDecoderSeekCallback,
            flacDecoderTellCallback,
            flacDecoderLengthCallback,
            flacDecoderEofCallback,
            flacDecoderWriteCallback,
            flacDecoderMetadataCallback,
            flacDecoderErrorCallback,
            Unmanaged.passUnretained(source).toOpaque()
        )
        guard status == FLAC__STREAM_DECODER_INIT_STATUS_OK else {
            FLAC__stream_decoder_delete(decoder)
            try? handle.close()
            throw decodeInitError(for: status, url: url)
        }
        return (source, decoder)
    }

    private func processMetadata(
        decoder: UnsafeMutablePointer<FLAC__StreamDecoder>,
        source: FLACSource,
        url: URL
    ) throws {
        guard FLAC__stream_decoder_process_until_end_of_metadata(decoder) != 0, source.decodeError == nil else {
            throw TranscodeError.decodeFailed(url)
        }
        source.channels = max(1, source.channels)
        source.bitsPerSample = max(1, source.bitsPerSample)
    }

    private func decodeInitError(
        for status: FLAC__StreamDecoderInitStatus,
        url: URL
    ) -> TranscodeError {
        switch status {
        case FLAC__STREAM_DECODER_INIT_STATUS_MEMORY_ALLOCATION_ERROR:
            return .bufferAllocation
        default:
            return .decodeFailed(url)
        }
    }
}

/// Public summary of one range decode's source access (§19.3).
public struct FLACDecodeStats: Sendable, Equatable {
    /// Total bytes read from the source file during the decode (metadata,
    /// seek positioning, and the requested range). For a multi-hour file this
    /// must be a small fraction of the file size.
    public var bytesReadFromSource: UInt64
    /// Source sample frames decoded before any resampling (the requested range
    /// plus bounded lookahead).
    public var decodedSourceFrames: Int

    public init(bytesReadFromSource: UInt64, decodedSourceFrames: Int) {
        self.bytesReadFromSource = bytesReadFromSource
        self.decodedSourceFrames = decodedSourceFrames
    }
}

// MARK: - libFLAC stream-decoder callbacks

/// The per-decode I/O state, referenced from the C callbacks through
/// `client_data`. Kept alive by the synchronous Swift stack for the duration
/// of a decode, so unretained bridging is safe.
private final class FLACSource {
    let handle: FileHandle
    let size: UInt64
    var offset: UInt64 = 0
    var bytesRead: UInt64 = 0
    let forceNonSeekable: Bool
    var seekUnsupported = false
    var decodeError: String?
    var channels = 1
    var bitsPerSample = 16
    var sampleRate = 0.0
    var totalSamples: UInt64 = 0
    var samples: [Float] = []

    init(handle: FileHandle, size: UInt64, forceNonSeekable: Bool) {
        self.handle = handle
        self.size = size
        self.forceNonSeekable = forceNonSeekable
    }
}

private func flacDecoderReadCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ bytes: UnsafeMutablePointer<Int>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderReadStatus {
    guard let clientData, let buffer, let bytes else {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    guard source.offset < source.size else {
        bytes.pointee = 0
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
    }
    do {
        let requested = min(bytes.pointee, Int(source.size - source.offset))
        guard requested > 0 else {
            bytes.pointee = 0
            return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
        }
        guard let data = try source.handle.read(upToCount: requested), !data.isEmpty else {
            bytes.pointee = 0
            return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM
        }
        data.withUnsafeBytes { raw in
            buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: data.count)
        }
        source.offset += UInt64(data.count)
        source.bytesRead += UInt64(data.count)
        bytes.pointee = data.count
        return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE
    } catch {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT
    }
}

private func flacDecoderSeekCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ absoluteByteOffset: UInt64,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderSeekStatus {
    guard let clientData else {
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR
    }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    if source.forceNonSeekable {
        source.seekUnsupported = true
        return FLAC__STREAM_DECODER_SEEK_STATUS_UNSUPPORTED
    }
    do {
        try source.handle.seek(toOffset: absoluteByteOffset)
        source.offset = absoluteByteOffset
        return FLAC__STREAM_DECODER_SEEK_STATUS_OK
    } catch {
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR
    }
}

private func flacDecoderTellCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ absoluteByteOffset: UnsafeMutablePointer<UInt64>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderTellStatus {
    guard let clientData, let absoluteByteOffset else {
        return FLAC__STREAM_DECODER_TELL_STATUS_ERROR
    }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    absoluteByteOffset.pointee = source.offset
    return FLAC__STREAM_DECODER_TELL_STATUS_OK
}

private func flacDecoderLengthCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ streamLength: UnsafeMutablePointer<UInt64>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderLengthStatus {
    guard let clientData, let streamLength else {
        return FLAC__STREAM_DECODER_LENGTH_STATUS_ERROR
    }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    streamLength.pointee = source.size
    return FLAC__STREAM_DECODER_LENGTH_STATUS_OK
}

private func flacDecoderEofCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__bool {
    guard let clientData else { return 1 }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    return source.offset >= source.size ? 1 : 0
}

private func flacDecoderWriteCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ frame: UnsafePointer<FLAC__Frame>?,
    _ buffer: UnsafePointer<UnsafePointer<FLAC__int32>?>?,
    _ clientData: UnsafeMutableRawPointer?
) -> FLAC__StreamDecoderWriteStatus {
    guard let clientData, let buffer else {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
    }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    guard source.decodeError == nil, let frame else {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT
    }
    // Use the frame's own blocksize, NOT FLAC__stream_decoder_get_blocksize:
    // after seek_absolute delta-shifts the first frame, get_blocksize still
    // reports the unshifted size and the buffer only holds blocksize-delta
    // samples — reading the larger count runs off the end of the frame.
    let blocksize = Int(frame.pointee.header.blocksize)
    guard blocksize > 0 else { return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE }
    let channels = source.channels
    let scale = Double(1 << (source.bitsPerSample - 1))
    source.samples.reserveCapacity(source.samples.count + blocksize)
    for i in 0..<blocksize {
        var sum: Double = 0
        for channel in 0..<channels {
            sum += Double(buffer[channel]![i])
        }
        source.samples.append(Float(sum / (scale * Double(channels))))
    }
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE
}

private func flacDecoderMetadataCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ metadata: UnsafePointer<FLAC__StreamMetadata>?,
    _ clientData: UnsafeMutableRawPointer?
) {
    guard let clientData, let metadata, metadata.pointee.type == FLAC__METADATA_TYPE_STREAMINFO else { return }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    let info = metadata.pointee.data.stream_info
    source.channels = Int(info.channels)
    source.bitsPerSample = Int(info.bits_per_sample)
    source.sampleRate = Double(info.sample_rate)
    source.totalSamples = info.total_samples
}

private func flacDecoderErrorCallback(
    _ decoder: UnsafePointer<FLAC__StreamDecoder>?,
    _ status: FLAC__StreamDecoderErrorStatus,
    _ clientData: UnsafeMutableRawPointer?
) {
    guard let clientData else { return }
    let source = Unmanaged<FLACSource>.fromOpaque(clientData).takeUnretainedValue()
    if source.decodeError == nil {
        source.decodeError = "libFLAC error status \(status.rawValue)"
    }
}
