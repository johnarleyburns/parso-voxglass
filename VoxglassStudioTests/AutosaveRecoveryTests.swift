import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// Spec §19.4 / §7.7: crash recovery — a synthetic `session.json` plus a WAV
/// with a stale header (as left by an AVAudioFile that was never closed) is
/// repaired and offered for recovery; keep ingests a labeled take, discard
/// removes the session and the file.
@MainActor
@Suite struct AutosaveRecoveryTests {

    @MainActor
    private struct Harness {
        let packageRoot: URL
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let project: AudiobookProject
        let paragraph: Paragraph
        let session: AutosaveSession
        let sessionURL: URL

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("voxglass-recovery-\(UUID().uuidString)")
                .appendingPathComponent("recover.voxproject")
            try? FileManager.default.createDirectory(at: root.appendingPathComponent("Autosave/takes"), withIntermediateDirectories: true)
            packageRoot = root
            sessionURL = root.appendingPathComponent("Autosave/session.json")

            let ids = SequentialIDGenerator()
            let clock = FixedClock()
            let text = "Recovered paragraph text for the crash-recovery acceptance test."
            paragraph = Paragraph(id: ids.next(), ordinal: 3, text: text, textHash: SHA256Hex.hex(Data(text.utf8)))
            let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter", paragraphs: [paragraph])
            project = AudiobookProject(
                id: ids.next(),
                metadata: BookMetadata(title: "Recovery Book", author: "A", narrator: "N"),
                chapters: [chapter],
                createdAt: clock.now,
                modifiedAt: clock.now
            )
            session = AutosaveSession(
                takeID: ids.next(),
                paragraphID: paragraph.id,
                chapterID: chapter.id,
                filePath: "Autosave/takes/crashed.wav",
                format: AutosaveSession.Format(sampleRate: 48_000, channels: 1, bitDepth: 16),
                startedAt: clock.now.timeIntervalSince1970,
                appVersion: "test"
            )
        }

        func writeSessionAndWAV(withStaleHeader stale: Bool, toneFrames: Int = 2400) throws -> URL {
            try AutosaveSessionFile.write(session, to: sessionURL)
            let wavURL = packageRoot.appendingPathComponent(session.filePath)
            writeWAV(at: wavURL, toneFrames: toneFrames, staleHeader: stale)
            return wavURL
        }

        func model() -> AutosaveRecoveryModel {
            AutosaveRecoveryModel(packageRoot: packageRoot, store: store, assets: assets, project: project)
        }

        private func writeWAV(at url: URL, toneFrames: Int, staleHeader: Bool) {
            let dataBytes = toneFrames * 2
            let declaredData = staleHeader ? dataBytes + 4096 : dataBytes
            var data = Data(capacity: 44 + dataBytes)
            func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
            func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

            append(Array("RIFF".utf8)); le32(UInt32(36 + declaredData))
            append(Array("WAVE".utf8))
            append(Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(48_000); le32(96_000); le16(2); le16(16)
            append(Array("data".utf8)); le32(UInt32(declaredData))
            for i in 0..<toneFrames {
                let v = Int16((0.4 * sin(2 * .pi * 440.0 * Double(i) / 48_000.0) * 32767.0).rounded())
                le16(UInt16(bitPattern: v))
            }
            try! data.write(to: url)
        }
    }

    @Test func keepRecoversTakeWithLabelAndDeletesSession() async throws {
        let h = Harness()
        try h.writeSessionAndWAV(withStaleHeader: true)
        try await h.store.save(h.project)

        let model = h.model()
        #expect(model.canRecover)
        #expect(model.duration > 0)

        await model.keepAsTake()

        let reloaded = try await h.store.load()
        let takes = reloaded.allParagraphs.flatMap(\.takes)
        #expect(takes.count == 1)
        let take = try #require(takes.first)
        #expect(take.origin == .recorded)
        #expect(take.label == "Recovered")
        #expect(take.paragraphID == h.paragraph.id)
        #expect(take.textHashAtRecording == h.paragraph.textHash)
        #expect(!take.assetRef.sha256.isEmpty)
        #expect(take.assetRef.byteCount > 0)

        let stored = try await h.assets.data(for: take.assetRef)
        #expect(SHA256Hex.hex(stored) == take.assetRef.sha256)
        #expect(!FileManager.default.fileExists(atPath: h.sessionURL.path), "session.json must be deleted after keep")
    }

    @Test func staleHeaderIsRepairedBeforeRecovery() async throws {
        let h = Harness()
        let wavURL = try h.writeSessionAndWAV(withStaleHeader: true)
        try await h.store.save(h.project)

        #expect(try WAVHeaderRepair.repairInPlace(url: wavURL) == true)

        let data = try Data(contentsOf: wavURL)
        let dataSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        #expect(UInt32(data.count - 44) == dataSize, "data chunk size must match actual bytes after repair")
        let riffSize = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        #expect(UInt32(data.count - 8) == riffSize)

        let model = h.model()
        #expect(model.canRecover)
    }

    @Test func discardRemovesSessionAndFile() async throws {
        let h = Harness()
        let wavURL = try h.writeSessionAndWAV(withStaleHeader: false)
        try await h.store.save(h.project)

        let model = h.model()
        #expect(model.canRecover)
        await model.discard()

        #expect(!FileManager.default.fileExists(atPath: h.sessionURL.path))
        #expect(!FileManager.default.fileExists(atPath: wavURL.path))
        let reloaded = try await h.store.load()
        #expect(reloaded.allParagraphs.flatMap(\.takes).isEmpty)
    }

    @Test func unreadableWAVIsNotRecoverable() async throws {
        let h = Harness()
        try AutosaveSessionFile.write(h.session, to: h.sessionURL)
        try await h.store.save(h.project)

        let model = h.model()
        #expect(!model.canRecover, "an empty/missing WAV must not offer recovery")
        #expect(model.error != nil)
    }

    @Test func healthyHeaderIsNotModified() async throws {
        let h = Harness()
        let wavURL = try h.writeSessionAndWAV(withStaleHeader: false)
        let before = try Data(contentsOf: wavURL)
        #expect(try WAVHeaderRepair.repairInPlace(url: wavURL) == false)
        let after = try Data(contentsOf: wavURL)
        #expect(before == after)
    }

    // MARK: - WAV helper (48 kHz mono 16-bit; optional stale header)

    private func writeWAV(at url: URL, toneFrames: Int, staleHeader: Bool) {
        let dataBytes = toneFrames * 2
        let declaredData = staleHeader ? dataBytes + 4096 : dataBytes
        var data = Data(capacity: 44 + dataBytes)
        func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        append(Array("RIFF".utf8)); le32(UInt32(36 + declaredData))
        append(Array("WAVE".utf8))
        append(Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(48_000); le32(96_000); le16(2); le16(16)
        append(Array("data".utf8)); le32(UInt32(declaredData))
        for i in 0..<toneFrames {
            let v = Int16((0.4 * sin(2 * .pi * 440.0 * Double(i) / 48_000.0) * 32767.0).rounded())
            le16(UInt16(bitPattern: v))
        }
        try! data.write(to: url)
    }
}
