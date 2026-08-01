import Foundation
import Observation
import VoxglassCore

/// Drives the spec §7.7 recovery sheet: a `session.json` found at package-open
/// time means a take from a crashed session can be recovered. The WAV is
/// validated (repairing a stale header first); on keep it is ingested as a
/// take with `origin = .recorded` and label "Recovered"; on discard the session
/// file and the WAV are removed.
@MainActor
@Observable
public final class AutosaveRecoveryModel {
    public private(set) var session: AutosaveSession?
    public private(set) var paragraph: Paragraph?
    public private(set) var duration: TimeInterval = 0
    public private(set) var isProcessing = false
    public var error: String?
    public var didFinish = false

    private let packageRoot: URL
    private let store: any ProductionStore
    private let assets: any ContentAddressedStore
    private let project: AudiobookProject?

    public init(
        packageRoot: URL,
        store: any ProductionStore,
        assets: any ContentAddressedStore,
        project: AudiobookProject?
    ) {
        self.packageRoot = packageRoot
        self.store = store
        self.assets = assets
        self.project = project
        load()
    }

    public var canRecover: Bool { session != nil }

    public var paragraphLabel: String {
        guard let session else { return "" }
        if let paragraph {
            let chapter = project?.chapters.first { $0.paragraphs.contains { $0.id == paragraph.id } }
            return "¶ \(chapter.map { "\($0.ordinal + 1) · \(paragraph.ordinal + 1)" } ?? "\(paragraph.ordinal + 1)")"
        }
        return "¶ \(session.paragraphID.uuidString.prefix(8))"
    }

    private func wavURL(for session: AutosaveSession) -> URL {
        packageRoot.appendingPathComponent(session.filePath)
    }

    private func load() {
        guard let session = try? AutosaveSessionFile.read(from: packageRoot.appendingPathComponent("Autosave/session.json")) else {
            return
        }
        let url = wavURL(for: session)

        // A WAV written by AVAudioFile that was never closed has a stale header
        // length; repair the RIFF/data chunk sizes from the actual file length.
        do {
            _ = try WAVHeaderRepair.repairInPlace(url: url)
        } catch {
            self.error = "Recovered recording could not be read: \(error.localizedDescription)"
        }

        let frameCount = try? wavFrameCount(url)
        guard let frameCount, frameCount > 0 else {
            self.error = "Recovered recording is empty or unreadable."
            return
        }
        self.duration = Double(frameCount) / session.format.sampleRate
        self.session = session
        self.paragraph = project?.allParagraphs.first { $0.id == session.paragraphID }
    }

    private func wavFrameCount(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard data.count > 44, String(decoding: data.prefix(4), as: UTF8.self) == "RIFF" else { throw WAVHeaderRepair.RepairError.notAWAV }
        let dataSize = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        let blockAlign = data.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt16.self) }
        guard blockAlign > 0 else { throw WAVHeaderRepair.RepairError.truncatedHeader }
        return Int(dataSize) / Int(blockAlign)
    }

    public func keepAsTake() async {
        guard let session, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        do {
            let url = wavURL(for: session)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AutosaveRecoveryError.fileMissing
            }
            let assetRef = try await assets.ingest(
                fileAt: url,
                ext: "wav",
                contentType: "audio/wav",
                subdirectory: .original,
                moving: true
            )
            let take = Take(
                id: session.takeID,
                paragraphID: session.paragraphID,
                assetRef: assetRef,
                origin: .recorded,
                recordedAt: Date(timeIntervalSince1970: session.startedAt),
                duration: duration,
                format: AudioFormatDescription(
                    sampleRate: session.format.sampleRate,
                    channels: session.format.channels,
                    bitDepth: session.format.bitDepth,
                    codec: "pcm"
                ),
                label: "Recovered",
                textHashAtRecording: paragraph?.textHash ?? ""
            )
            try await store.insertTake(take)
            AutosaveSessionFile.delete(at: packageRoot.appendingPathComponent("Autosave/session.json"))
            didFinish = true
        } catch {
            self.error = "Recovery failed: \(error.localizedDescription)"
        }
    }

    public func discard() async {
        guard let session, !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        AutosaveSessionFile.delete(at: packageRoot.appendingPathComponent("Autosave/session.json"))
        try? FileManager.default.removeItem(at: wavURL(for: session))
        didFinish = true
    }
}

public enum AutosaveRecoveryError: Error {
    case fileMissing
}
