import Foundation
import OSLog
import VoxglassCore

/// Logging categories (§4.6). Never log paragraph text, project titles, or
/// file paths at `.info` or above — use IDs (the manuscript may be under NDA).
public enum Log {
    public static let capture   = Logger(subsystem: "guru.parso.voxglass.studio", category: "capture")
    public static let store     = Logger(subsystem: "guru.parso.voxglass.studio", category: "store")
    public static let assembly  = Logger(subsystem: "guru.parso.voxglass.studio", category: "assembly")
    public static let sync      = Logger(subsystem: "guru.parso.voxglass.studio", category: "sync")
    public static let packaging = Logger(subsystem: "guru.parso.voxglass.studio", category: "packaging")
    public static let license   = Logger(subsystem: "guru.parso.voxglass.studio", category: "license")
}

/// The diagnostics bundle (spec §4.6, §21.5): a `.zip` the user can send for
/// support. Contains the project integrity report, schema version, entitlement
/// state, encoder availability, the audio input device list, storage figures,
/// and the last log lines from this process. **No audio and no text** — the
/// manuscript and recordings never leave the Mac in a diagnostics bundle.
public struct DiagnosticsBundleContent: Sendable, Equatable {
    public var appVersion: String
    public var schemaVersion: Int
    public var entitlement: String
    public var encoderAvailability: [String]
    public var inputDeviceLabel: String
    public var storageReport: String
    public var integrityFindings: [String]
    public var logTail: [String]

    public init(
        appVersion: String = "",
        schemaVersion: Int = 0,
        entitlement: String = "unknown",
        encoderAvailability: [String] = [],
        inputDeviceLabel: String = "system default",
        storageReport: String = "unavailable",
        integrityFindings: [String] = [],
        logTail: [String] = []
    ) {
        self.appVersion = appVersion
        self.schemaVersion = schemaVersion
        self.entitlement = entitlement
        self.encoderAvailability = encoderAvailability
        self.inputDeviceLabel = inputDeviceLabel
        self.storageReport = storageReport
        self.integrityFindings = integrityFindings
        self.logTail = logTail
    }

    /// The rendered text files that make up the bundle (filename → content).
    public func renderedFiles() -> [String: String] {
        var files: [String: String] = [:]

        files["diagnostics.txt"] = """
        Voxglass Studio diagnostics
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        App version: \(appVersion)
        Project schema version: \(schemaVersion)
        Entitlement: \(entitlement)
        Input device: \(inputDeviceLabel)
        Encoders available: \(encoderAvailability.isEmpty ? "none" : encoderAvailability.sorted().joined(separator: ", "))
        """

        files["storage.txt"] = storageReport

        if integrityFindings.isEmpty {
            files["integrity.txt"] = "Project integrity: no findings (shallow check).\n"
        } else {
            files["integrity.txt"] = integrityFindings.joined(separator: "\n") + "\n"
        }

        files["log.txt"] = logTail.isEmpty
            ? "No OSLog entries captured for this process.\n"
            : logTail.joined(separator: "\n") + "\n"

        files["README.txt"] = """
        Voxglass Studio diagnostics bundle.
        Contains no audio and no manuscript text. Send this zip with your
        support request. If you were asked for project details, reproduce the
        problem, then export a fresh bundle.
        """
        return files
    }
}

/// Assembles and zips a diagnostics bundle.
public enum DiagnosticsBundleWriter {

    /// The last N log lines for this process's Voxglass Studio subsystem,
    /// newest first. Uses OSLogStore so the shipped binary needs no
    /// app-side ring buffer.
    public static func logTail(last count: Int = 500) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let predicate = NSPredicate(format: "subsystem == %@", "guru.parso.voxglass.studio")
            let entries = try store.getEntries(with: [], matching: predicate)
                .compactMap { entry -> String? in
                    guard let logEntry = entry as? OSLogEntryLog else { return nil }
                    let date = ISO8601DateFormatter().string(from: logEntry.date)
                    let level: String
                    switch logEntry.level {
                    case .error: level = "error"
                    case .fault: level = "fault"
                    case .debug: level = "debug"
                    default: level = "info"
                    }
                    return "\(date) [\(level)] \(logEntry.composedMessage)"
                }
                .suffix(count)
            return Array(entries.reversed())
        } catch {
            return ["OSLog store unavailable: \(error.localizedDescription)"]
        }
    }

    /// Writes `files` into `directory` and zips them to `outputURL` via
    /// `ditto` (macOS-guaranteed). Returns the zip URL.
    @discardableResult
    public static func writeZip(_ files: [String: String], into directory: URL, outputURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, content) in files {
            let url = directory.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        try? FileManager.default.removeItem(at: outputURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, outputURL.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiagnosticsError.zipFailed(process.terminationStatus)
        }
        return outputURL
    }
}

public enum DiagnosticsError: Error, LocalizedError {
    case zipFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .zipFailed(let status): "ditto exited with status \(status)"
        }
    }
}
