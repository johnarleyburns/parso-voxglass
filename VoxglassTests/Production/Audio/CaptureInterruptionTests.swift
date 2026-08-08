import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// The interruption matrix (spec §7.4): every row ends the same way — a
/// playable take, a named cause, and a warning. One case per row.
///
/// Rows that reach the app as a notification (call/Siri/system, route change,
/// USB unplug, headphones removed, background/lock) all stop the capture
/// cleanly through `CaptureRecovery.handleInFlightInterruption`. Storage
/// pressure kills the writer mid-take, so the handler repairs the partial
/// file. Force-quit never runs in-process; `recoverAfterLaunch` recovers the
/// repaired file at the next open.
@Suite struct CaptureInterruptionTests {

    // MARK: - In-flight rows (clean capture stop)

    private func cleanStopReasons() -> [CaptureInterruptionReason] {
        [.phoneCallOrSystem, .routeChanged, .deviceUnplugged, .headphonesRemoved, .backgroundedOrLocked]
    }

    @Test(arguments: [
        (reason: CaptureInterruptionReason.phoneCallOrSystem, name: "phone call or system interruption"),
        (reason: CaptureInterruptionReason.routeChanged, name: "route change"),
        (reason: CaptureInterruptionReason.deviceUnplugged, name: "USB unplug"),
        (reason: CaptureInterruptionReason.headphonesRemoved, name: "headphones removed"),
        (reason: CaptureInterruptionReason.backgroundedOrLocked, name: "app backgrounded or locked")
    ])
    func interruptionPreservesPlayableInterruptedTake(
        reason: CaptureInterruptionReason, name: String
    ) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("take-\(reason.rawValue).wav")

        let fake = FakeAudioCapture()
        try await fake.prepare(device: nil, format: RecordingDefaults())
        try await fake.startRecording(to: url)

        let recovered = try await CaptureRecovery.handleInFlightInterruption(reason: reason, capture: fake, destinationURL: url)

        #expect(recovered.reason == reason)
        #expect(recovered.warning == .interrupted)
        #expect(recovered.duration > 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let info = try WAVFormatReader.read(url: url)
        #expect(info.dataByteCount > 0)
        #expect(info.duration == recovered.duration)
    }

    @Test func diskPressureRepairsPartialFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("disk-pressure.wav")

        let fake = FakeAudioCapture()
        fake.interruptionError = FakeCaptureError.diskFull
        fake.staleHeaderFile = true
        try await fake.prepare(device: nil, format: RecordingDefaults())
        try await fake.startRecording(to: url)

        let recovered = try await CaptureRecovery.handleInFlightInterruption(reason: .diskPressure, capture: fake, destinationURL: url)

        #expect(recovered.warning == .interrupted)
        #expect(recovered.reason == .diskPressure)
        // The writer died mid-take; the header had to be rewritten to match
        // the bytes that actually hit disk.
        #expect(recovered.headerRepaired == true)
        #expect(recovered.duration > 0)
        let info = try WAVFormatReader.read(url: url)
        #expect(info.dataByteCount > 0)
        #expect(info.duration == recovered.duration)
    }

    // MARK: - Force-quit row (relaunch recovery)

    @Test func forceQuitRecoversAtNextLaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
        let autosaveDir = dir.appendingPathComponent("Autosave")
        let takesDir = autosaveDir.appendingPathComponent("takes")
        try FileManager.default.createDirectory(at: takesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let filePath = "Autosave/takes/crashed.wav"
        let fileURL = dir.appendingPathComponent(filePath)
        let sessionURL = autosaveDir.appendingPathComponent("session.json")

        // The session is written before recording starts (§7.7); the app is
        // force-quit mid-take, leaving a stale-header WAV behind.
        let session = AutosaveSession(
            takeID: UUID(),
            paragraphID: UUID(),
            chapterID: nil,
            filePath: filePath,
            format: AutosaveSession.Format(sampleRate: 48_000, channels: 1, bitDepth: 16),
            startedAt: 0,
            appVersion: "test"
        )
        try AutosaveSessionFile.write(session, to: sessionURL)

        let fake = FakeAudioCapture()
        fake.staleHeaderFile = true
        try await fake.prepare(device: nil, format: RecordingDefaults())
        try await fake.startRecording(to: fileURL)
        // Simulate the crash: never call stopRecording, never delete session.json.

        let recovered = try #require(try CaptureRecovery.recoverAfterLaunch(sessionURL: sessionURL))

        #expect(recovered.warning == .interrupted)
        #expect(recovered.reason == .forceQuit)
        #expect(recovered.headerRepaired == true)
        #expect(recovered.duration > 0)
        let info = try WAVFormatReader.read(url: fileURL)
        #expect(info.dataByteCount > 0)
        #expect(info.duration == recovered.duration)
    }

    @Test func recoverySkipsInvalidFileWithoutThrowing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
        let autosaveDir = dir.appendingPathComponent("Autosave")
        try FileManager.default.createDirectory(at: autosaveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionURL = autosaveDir.appendingPathComponent("session.json")
        let session = AutosaveSession(
            takeID: UUID(),
            paragraphID: UUID(),
            chapterID: nil,
            filePath: "Autosave/takes/corrupt.wav",
            format: AutosaveSession.Format(sampleRate: 48_000, channels: 1, bitDepth: 16),
            startedAt: 0,
            appVersion: "test"
        )
        try AutosaveSessionFile.write(session, to: sessionURL)
        let corrupt = dir.appendingPathComponent("Autosave/takes/corrupt.wav")
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a wav at all".utf8).write(to: corrupt)

        // A corrupt file must be skipped (nil), never thrown — a failed single
        // project recovery must not abort launch (§4.3.3 parallel rule).
        let recovered = try CaptureRecovery.recoverAfterLaunch(sessionURL: sessionURL)
        #expect(recovered == nil)
    }

    @Test func noSessionMeansNoRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recovered = try CaptureRecovery.recoverAfterLaunch(
            sessionURL: dir.appendingPathComponent("Autosave/session.json")
        )
        #expect(recovered == nil)
    }

    // MARK: - Persistence (§7.1, §7.4): warning + route survive the store

    @Test func interruptedTakeFieldsSurviveStoreRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("takes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        var project = ProjectFixtures.tiny()
        let pid = project.chapters[0].paragraphs[0].id

        let take = Take(
            id: ids.next(),
            paragraphID: pid,
            assetRef: AudioAssetReference(
                sha256: SHA256Hex.hex(Data("interrupted".utf8)),
                relativePath: "Audio/Original/aa/bb/interrupted.wav",
                byteCount: 100,
                contentType: "audio/wav"
            ),
            origin: .recorded,
            recordedAt: clock.now,
            duration: 1.0,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, bitDepth: 16, codec: "pcm"),
            textHashAtRecording: "hash",
            warning: .interrupted,
            routeClass: .draftOnly
        )
        project.chapters[0].paragraphs[0].takes = [take]
        project.chapters[0].paragraphs[0].selectedTakeID = take.id

        let store = SQLiteProductionStore(databaseURL: url)
        try await store.save(project)

        let loaded = try await store.load()
        let persisted = loaded.allParagraphs.first { $0.id == pid }?.takes.first
        #expect(persisted?.id == take.id)
        #expect(persisted?.warning == .interrupted)
        #expect(persisted?.routeClass == .draftOnly)
    }

    @Test func migrationAddsCaptureColumnsWithSafeDefaults() async throws {
        let db = ProjectDatabase.makeTemporary(named: "capture-columns")
        try await db.prepare()

        let columns = try await db.queryRaw("PRAGMA table_info(take)")
        let names = Set(columns.compactMap { $0.string("name") })
        #expect(names.contains("capture_warning"))
        #expect(names.contains("route_class"))

        // A take inserted without the new columns (a legacy code path) still
        // stores; the defaults read back as `.none` / nil.
        let proj = UUID().uuidString
        let chap = UUID().uuidString
        let para = UUID().uuidString
        let id = UUID().uuidString
        try await db.execute("""
            INSERT INTO project (id, title, author, narrator, purpose, intended_destination, rights_basis, recording_json, assembly_json, created_at, modified_at, schema_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.string(proj), .string("T"), .string("A"), .string("N"),
                  .string("publicDomainCommunity"), .string("librivox"), .string("publicDomainUS"),
                  .string("{}"), .string("{}"), .double(0), .double(0), .int(1)])
        try await db.execute("""
            INSERT INTO chapter (id, project_id, ordinal, title)
            VALUES (?, ?, ?, ?)
            """, [.string(chap), .string(proj), .int(0), .string("Ch")])
        try await db.execute("""
            INSERT INTO paragraph (id, chapter_id, project_id, ordinal, text, text_hash, review_state, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, [.string(para), .string(chap), .string(proj), .int(0), .string("P"), .string("h"),
                  .string("unreviewed"), .double(0)])
        try await db.execute("""
            INSERT INTO take (id, paragraph_id, project_id, asset_sha256, asset_path, asset_bytes, asset_content_type, origin_kind, recorded_at, duration, sample_rate, channels, codec, text_hash_at_recording)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.string(id), .string(para), .string(proj),
                  .string("abc"), .string("Audio/Original/a"), .int(1), .string("audio/wav"),
                  .string("recorded"), .double(0), .double(1), .double(48000), .int(1),
                  .string("pcm"), .string("h")])
        let rows = try await db.queryRaw("SELECT capture_warning, route_class FROM take WHERE id = '\(id)'")
        #expect(rows.count == 1)
        #expect(rows[0].string("capture_warning") == "none")
        #expect(rows[0].string("route_class") == nil)
    }
}
