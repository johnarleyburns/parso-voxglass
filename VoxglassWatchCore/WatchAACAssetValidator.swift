import AVFoundation
import Foundation

/// The single acceptance contract for Watch narration audio. Used by the iPhone before an
/// artifact is advertised, cached, or transferred, and by the Watch when installing it.
public enum WatchAACAssetValidator {
    public static func validate(_ url: URL) throws {
        guard url.isFileURL,
              url.pathExtension.lowercased() == "m4a" else {
            throw WatchAACAssetValidationError.wrongContainer
        }

        // Unreadable bytes (garbage, truncated, empty) surface as a typed, stable error.
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw WatchAACAssetValidationError.wrongCodec }
        guard file.length > 0 else {
            throw WatchAACAssetValidationError.emptyAudio
        }
        guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC else {
            throw WatchAACAssetValidationError.wrongCodec
        }
    }
}

public enum WatchAACAssetValidationError: Error, LocalizedError, Equatable, Sendable {
    case wrongContainer
    case emptyAudio
    case wrongCodec

    public var errorDescription: String? {
        switch self {
        case .wrongContainer: return "The file is not an .m4a container."
        case .emptyAudio: return "The audio contains no playable samples."
        case .wrongCodec: return "The audio is not AAC."
        }
    }
}
