import Foundation

/// Orchestrates the interruption matrix (spec §7.4): every row ends with a
/// playable take, a named cause, and a way back. Two entry points:
///
/// - `handleInFlightInterruption` — the app calls this the moment a phone
///   call, Siri, route change, USB unplug, headphone removal, background, or
///   storage failure interrupts a take. It stops the capture, finalizes the
///   file (repairing the header if the writer died mid-take), and returns a
///   playable, `.interrupted` take.
/// - `recoverAfterLaunch` — the app calls this at open when an autosave
///   session is present (a force-quit left `session.json` behind). It
///   validates and repairs the file and returns a playable, `.interrupted`
///   take, or `nil` when the file is invalid.
public enum CaptureRecovery {
    public enum RecoveryError: Error, Equatable {
        /// The capture was not recording when the interruption handler ran.
        case notRecording
        /// The file left on disk is not a valid, repairable WAV.
        case invalidFile
    }

    /// In-flight interruption path (§7.4 rows 1–6). Attempts a clean capture
    /// stop; on failure (storage pressure, writer failure) it repairs whatever
    /// hit the disk and recovers the partial file.
    public static func handleInFlightInterruption(
        reason: CaptureInterruptionReason,
        capture: any AudioCapturing,
        destinationURL: URL
    ) async throws -> RecoveredCapture {
        do {
            let captured = try await capture.stopRecording()
            return RecoveredCapture(
                fileURL: captured.fileURL,
                format: captured.format,
                duration: captured.duration,
                peakDBFS: captured.peakDBFS,
                clippedDuringCapture: captured.clippedDuringCapture,
                reason: reason,
                warning: .interrupted,
                headerRepaired: false
            )
        } catch {
            // The writer failed mid-take (disk pressure or a dead engine). The
            // partial file is still on disk; repair and recover it.
            let repaired = try repairAndRead(at: destinationURL)
            return RecoveredCapture(
                fileURL: repaired.url,
                format: repaired.info.audioFormat,
                duration: repaired.info.duration,
                peakDBFS: repaired.peakDBFS,
                clippedDuringCapture: repaired.clipped,
                reason: reason,
                warning: .interrupted,
                headerRepaired: repaired.headerRepaired
            )
        }
    }

    /// Relaunch recovery path (§7.4 row 7). Returns `nil` when no session is
    /// present or the file is not a playable WAV; a failed single project
    /// recovery must never abort the rest of launch.
    public static func recoverAfterLaunch(sessionURL: URL) throws -> RecoveredCapture? {
        guard let session = try AutosaveSessionFile.read(from: sessionURL) else { return nil }
        let packageRoot = sessionURL
            .deletingLastPathComponent() // .../Autosave
            .deletingLastPathComponent() // package root
        let fileURL = packageRoot.appendingPathComponent(session.filePath)
        do {
            let repaired = try repairAndRead(at: fileURL)
            return RecoveredCapture(
                fileURL: repaired.url,
                format: repaired.info.audioFormat,
                duration: repaired.info.duration,
                peakDBFS: repaired.peakDBFS,
                clippedDuringCapture: repaired.clipped,
                reason: .forceQuit,
                warning: .interrupted,
                headerRepaired: repaired.headerRepaired
            )
        } catch {
            return nil
        }
    }

    // MARK: - Shared

    private struct RepairedFile {
        var url: URL
        var info: WAVFormatInfo
        var headerRepaired: Bool
        var peakDBFS: Double
        var clipped: Bool
    }

    private static func repairAndRead(at url: URL) throws -> RepairedFile {
        guard FileManager.default.fileExists(atPath: url.path) else { throw RecoveryError.invalidFile }
        let repaired: Bool
        do {
            repaired = try WAVHeaderRepair.repairInPlace(url: url)
        } catch {
            throw RecoveryError.invalidFile
        }
        let info: WAVFormatInfo
        do {
            info = try WAVFormatReader.read(url: url)
        } catch {
            throw RecoveryError.invalidFile
        }
        guard info.dataByteCount > 0, info.duration > 0 else { throw RecoveryError.invalidFile }
        return RepairedFile(url: url, info: info, headerRepaired: repaired, peakDBFS: -60, clipped: false)
    }
}
