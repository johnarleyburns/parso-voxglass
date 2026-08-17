import AppKit
import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// S12 diagnostics bundle (§4.6, §21.5): the zip contains the integrity
/// report, schema version, entitlement state, encoder availability, storage
/// figures, and log lines — and never audio or manuscript text.
@Suite struct DiagnosticsBundleTests {

    @Test func renderedFilesContainRequiredSections() {
        let content = DiagnosticsBundleContent(
            appVersion: "Voxglass Studio 1.0",
            schemaVersion: 1,
            entitlement: "free",
            encoderAvailability: ["mp3", "flac"],
            inputDeviceLabel: "USB Interface",
            storageReport: "Storage report\n1 MB originals\n",
            integrityFindings: ["blocking: selectedTakeMissing — a paragraph has no selected take"],
            logTail: ["2026-08-02T00:00:00Z [info] export started"]
        )

        let files = content.renderedFiles()

        #expect(files["diagnostics.txt"] != nil)
        let diagnostics = files["diagnostics.txt"] ?? ""
        #expect(diagnostics.contains("App version: Voxglass Studio 1.0"))
        #expect(diagnostics.contains("Project schema version: 1"))
        #expect(diagnostics.contains("Entitlement: free"))
        #expect(diagnostics.contains("Encoders available: flac, mp3"))

        #expect(files["integrity.txt"]?.contains("selectedTakeMissing") == true)
        #expect(files["storage.txt"]?.contains("Storage report") == true)
        #expect(files["log.txt"]?.contains("export started") == true)
        #expect(files["README.txt"]?.contains("no audio and no manuscript text") == true)
    }

    @Test func emptyFindingsReportAsClean() {
        let files = DiagnosticsBundleContent(integrityFindings: []).renderedFiles()
        #expect(files["integrity.txt"]?.contains("no findings") == true)
    }

    @Test func logTailNeverFallsOver() {
        // Must return *something* (even a failure message), never throw.
        let tail = DiagnosticsBundleWriter.logTail()
        #expect(tail.count >= 0)
        #expect(tail.count <= 500)
    }

    @Test func writeZipProducesVerifiableZip() throws {
        let content = DiagnosticsBundleContent(
            integrityFindings: ["warning: textHashMismatch — paragraph 42"],
            logTail: ["line one", "line two"]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsBundleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let zipURL = try DiagnosticsBundleWriter.writeZip(
            content.renderedFiles(),
            into: directory.appendingPathComponent("voxglass-diagnostics", isDirectory: true),
            outputURL: directory.appendingPathComponent("voxglass-diagnostics.zip")
        )

        #expect(FileManager.default.fileExists(atPath: zipURL.path))

        // Verify the zip opens and contains every expected file (ditto round-trip).
        let unzipDir = directory.appendingPathComponent("unzip", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, unzipDir.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let inner = unzipDir.appendingPathComponent("voxglass-diagnostics", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: inner.path).sorted()
        #expect(names.contains("diagnostics.txt"))
        #expect(names.contains("integrity.txt"))
        #expect(names.contains("log.txt"))
        #expect(names.contains("README.txt"))
    }
}
