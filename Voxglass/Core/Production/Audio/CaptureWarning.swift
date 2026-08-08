import Foundation

/// Persisted capture warning carried on a `Take` (spec §7.4). `.none` for a
/// clean take; `.interrupted` for a take finalized after an interruption.
public enum CaptureWarning: String, Codable, Sendable, Equatable {
    case none
    case interrupted
}

/// The named cause of a capture interruption (spec §7.4). Each row of the
/// interruption matrix maps to one case; the UI presents the cause and the
/// recovery flow records it so "never a silent loss" holds by construction.
public enum CaptureInterruptionReason: String, Codable, Sendable, CaseIterable {
    /// Phone call, Siri, alarm, or another app taking the audio session.
    case phoneCallOrSystem
    /// An `AVAudioSession` route change not otherwise attributed.
    case routeChanged
    /// A USB interface or USB microphone was unplugged.
    case deviceUnplugged
    /// Wired headphones or AirPods were removed.
    case headphonesRemoved
    /// Storage filled while writing the take.
    case diskPressure
    /// The app was backgrounded or the device locked.
    case backgroundedOrLocked
    /// The app was force-quit; recovered at next launch from the autosave
    /// session, so the in-process reason is unknowable.
    case forceQuit

    /// A short, user-facing cause description for the recovery banner.
    public var userDescription: String {
        switch self {
        case .phoneCallOrSystem: return "Phone call or system interruption"
        case .routeChanged: return "Your input device changed"
        case .deviceUnplugged: return "The input device was unplugged"
        case .headphonesRemoved: return "Headphones were removed"
        case .diskPressure: return "Storage filled during recording"
        case .backgroundedOrLocked: return "The app was backgrounded or the device locked"
        case .forceQuit: return "Recovered from a previous session"
        }
    }
}

/// The outcome of finalizing a take after an interruption, or recovering one
/// after a launch (spec §7.4). Always a playable file — the interruption
/// matrix ends with "a playable take, a named cause, and a way back".
public struct RecoveredCapture: Sendable, Equatable {
    /// The finalized file on disk (may have had its header repaired).
    public var fileURL: URL
    /// The take's actual audio format.
    public var format: AudioFormatDescription
    /// Recovered duration in seconds.
    public var duration: TimeInterval
    /// Peak level in dBFS measured up to the interruption.
    public var peakDBFS: Double
    /// Whether the captured audio clipped before the interruption.
    public var clippedDuringCapture: Bool
    /// Why the take was interrupted.
    public var reason: CaptureInterruptionReason
    /// Always `.interrupted` for a recovered take.
    public var warning: CaptureWarning
    /// True when `WAVHeaderRepair` had to rewrite the header before the file
    /// was playable (force-quit / disk-pressure artifact).
    public var headerRepaired: Bool

    public init(
        fileURL: URL,
        format: AudioFormatDescription,
        duration: TimeInterval,
        peakDBFS: Double,
        clippedDuringCapture: Bool,
        reason: CaptureInterruptionReason,
        warning: CaptureWarning,
        headerRepaired: Bool
    ) {
        self.fileURL = fileURL
        self.format = format
        self.duration = duration
        self.peakDBFS = peakDBFS
        self.clippedDuringCapture = clippedDuringCapture
        self.reason = reason
        self.warning = warning
        self.headerRepaired = headerRepaired
    }
}
