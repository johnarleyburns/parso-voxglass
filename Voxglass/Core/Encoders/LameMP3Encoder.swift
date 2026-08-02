import Lame
import Foundation
import VoxglassCore

/// Thin Swift wrapper over the LAME C API (§16.3).
///
/// LAME is the only way Voxglass can produce MP3 on macOS — AVFoundation
/// decodes MP3 but does not encode it. Voxglass encodes **CBR only**
/// (`lame_set_VBR(vbr_off)`): LibriVox rejects VBR and ACX requires CBR, so
/// there is no VBR path in this product. The Xing/Info frame is written
/// (`lame_set_bWriteVbrTag`) so downstream frame-header inspection can prove
/// CBR conformance (§19.3 `TranscoderCBRTests`).
///
/// The wrapper encodes mono float PCM. Input is always mono in this product
/// (the pipeline downmixes in the decoder).
public struct LameMP3Encoder: Sendable {

    public init() {}

    /// Encode `samples` (mono, at `sampleRate`) as CBR MP3 at `bitrateKbps`,
    /// prepending `headerData` (the ID3v2 tag) and writing to `outputURL`.
    /// Returns the number of bytes written.
    public func encode(
        samples: [Float],
        sampleRate: Double,
        bitrateKbps: Int,
        headerData: Data?,
        to outputURL: URL
    ) throws -> Int {
        guard let flags = lame_init() else {
            throw TranscodeError.nativeLibrary("lame_init")
        }
        defer { lame_close(flags) }

        lame_set_num_channels(flags, 1)
        lame_set_in_samplerate(flags, Int32(sampleRate))
        lame_set_brate(flags, Int32(bitrateKbps))
        lame_set_VBR(flags, vbr_off)       // CBR is the only mode this product ships.
        lame_set_quality(flags, 2)
        lame_set_bWriteVbrTag(flags, 1)    // Xing/Info header for CBR verification.

        guard lame_init_params(flags) == 0 else {
            throw TranscodeError.nativeLibrary("lame_init_params")
        }

        let chunkSize = 1152 * 16
        let mp3BufferSize = Int(1.25 * Double(chunkSize)) + 7200
        var mp3Buffer = [UInt8](repeating: 0, count: mp3BufferSize)
        var flushBuffer = [UInt8](repeating: 0, count: 8192)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        if let headerData, !headerData.isEmpty {
            try handle.write(contentsOf: headerData)
        }

        let pointer = samples.withUnsafeBufferPointer { $0.baseAddress }
        guard let pointer else {
            throw TranscodeError.bufferAllocation
        }

        var total: Int = 0
        var position = 0
        while position < samples.count {
            let count = min(chunkSize, samples.count - position)
            let encoded = lame_encode_buffer_ieee_float(
                flags, pointer + position, nil, Int32(count),
                &mp3Buffer, Int32(mp3Buffer.count)
            )
            if encoded > 0 {
                try handle.write(contentsOf: Data(mp3Buffer[0 ..< Int(encoded)]))
                total += Int(encoded)
            } else if encoded < 0 {
                throw TranscodeError.encoderFailed(status: Int(encoded), stderr: "LAME encode error \(encoded)")
            }
            position += count
        }

        let flushed = lame_encode_flush(flags, &flushBuffer, Int32(flushBuffer.count))
        if flushed > 0 {
            try handle.write(contentsOf: Data(flushBuffer[0 ..< Int(flushed)]))
            total += Int(flushed)
        }
        return total
    }
}
