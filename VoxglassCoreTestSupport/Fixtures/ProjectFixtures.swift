import Foundation
import CryptoKit
import VoxglassCore

public enum SimplePRNG {
    private nonisolated(unsafe) static var seed: UInt64 = 42

    public static func reseed(_ s: UInt64) { seed = s }

    public static func next() -> UInt64 {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return seed
    }

    public static func nextDouble() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }
}

public enum ProjectFixtures {
    public static func tiny() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let ch1 = makeChapter(ordinal: 0, title: "Chapter One", paraCount: 3, role: .body, ids: ids, clock: clock)
        let ch2 = makeChapter(ordinal: 1, title: "Chapter Two", paraCount: 3, role: .body, ids: ids, clock: clock)

        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(
                title: "Tiny Test Book",
                author: "Test Author",
                narrator: "Test Narrator"
            ),
            chapters: [ch1, ch2],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    public static func typical() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        var chapters: [ProductionChapter] = []
        for i in 0..<12 {
            let paraCount = 80 + Int(SimplePRNG.next() % 20)
            let isRecorded = SimplePRNG.nextDouble() < 0.42
            let isFlagged = SimplePRNG.nextDouble() < 0.06

            let ch = makeChapter(
                ordinal: i,
                title: "Chapter \(i + 1)",
                paraCount: paraCount,
                role: .body,
                ids: ids,
                clock: clock,
                recordedFraction: isRecorded ? 0.42 : 0,
                flaggedFraction: isFlagged ? 0.06 : 0
            )
            chapters.append(ch)
        }

        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(
                title: "Typical Test Book",
                author: "Test Author",
                narrator: "Test Narrator"
            ),
            chapters: chapters,
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    public static func stress(paragraphs: Int = 10_000) -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()
        SimplePRNG.reseed(42)

        let chaptersPer = max(1, paragraphs / 200)
        var chapters: [ProductionChapter] = []
        var remaining = paragraphs

        for i in 0..<chaptersPer {
            let count = min(remaining, paragraphs / chaptersPer + (i < paragraphs % chaptersPer ? 1 : 0))
            if count > 0 {
                chapters.append(makeChapter(
                    ordinal: i,
                    title: "Chapter \(i + 1)",
                    paraCount: count,
                    role: .body,
                    ids: ids,
                    clock: clock,
                    recordedFraction: 0.5,
                    flaggedFraction: 0.1
                ))
            }
            remaining -= count
        }

        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(
                title: "Stress Test Book",
                author: "Test Author",
                narrator: "Test Narrator"
            ),
            chapters: chapters,
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    public static func aiTainted() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let pID = ids.next()
        let takeID = ids.next()

        let assetRef = AudioAssetReference(
            sha256: "abc123", relativePath: "Audio/Original/ab/cd/abc.wav",
            byteCount: 1000, contentType: "public.wav"
        )

        let aiTake = Take(
            id: takeID,
            paragraphID: pID,
            assetRef: assetRef,
            origin: .aiImported(providerLabel: "TestAI"),
            recordedAt: clock.now,
            duration: 5.0,
            format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s24le"),
            textHashAtRecording: SHA256Hex.hex(Data("test".utf8))
        )

        let paragraph = Paragraph(
            id: pID,
            ordinal: 0,
            text: "AI-generated text",
            textHash: SHA256Hex.hex(Data("test".utf8)),
            takes: [aiTake],
            selectedTakeID: takeID
        )

        let chapter = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter 1", paragraphs: [paragraph])

        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "AI Tainted", author: "Author", narrator: "Narrator"),
            chapters: [chapter],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    public static func aiUnselected() -> AudiobookProject {
        let project = aiTainted()
        var chapters = project.chapters
        chapters[0].paragraphs[0].selectedTakeID = nil
        return AudiobookProject(
            id: project.id,
            metadata: project.metadata,
            chapters: chapters,
            createdAt: project.createdAt,
            modifiedAt: project.modifiedAt
        )
    }

    public static func drifted() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        func makePara(_ text: String, _ takeHash: String, _ selected: Bool) -> Paragraph {
            let pid = ids.next()
            let tid = ids.next()
            let assetRef = AudioAssetReference(sha256: "sha", relativePath: "path", byteCount: 100, contentType: "public.wav")
            let take = Take(id: tid, paragraphID: pid, assetRef: assetRef, origin: .recorded, recordedAt: clock.now, duration: 1.0, format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm"), textHashAtRecording: takeHash)
            return Paragraph(id: pid, ordinal: 0, text: text, textHash: SHA256Hex.hex(Data(text.utf8)), takes: [take], selectedTakeID: selected ? tid : nil)
        }

        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Drift Test", author: "A", narrator: "N"),
            chapters: [
                ProductionChapter(id: ids.next(), ordinal: 0, title: "Ch1", paragraphs: [
                    makePara("identical text.", SHA256Hex.hex(Data("identical text.".utf8)), true),
                    makePara("text with smart quotes changed.", SHA256Hex.hex(Data("text with smart quotes changed".utf8)), true),
                    makePara("minor change here.", SHA256Hex.hex(Data("minor change there".utf8)), true),
                    makePara("completely different paragraph now.", SHA256Hex.hex(Data("original text".utf8)), true)
                ])
            ],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    public static func brokenIntegrity() -> AudiobookProject {
        let ids = SequentialIDGenerator()
        let clock = FixedClock()

        let p1 = Paragraph(id: ids.next(), ordinal: 0, text: "P1", textHash: "h1")
        let p2 = Paragraph(id: ids.next(), ordinal: 0, text: "P2", textHash: "h2")
        let p3 = Paragraph(id: ids.next(), ordinal: 1, text: "P3", textHash: "h1")

        let ch1 = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter 1", paragraphs: [p1, p2])
        let ch2 = ProductionChapter(id: ids.next(), ordinal: 0, title: "Chapter 2", paragraphs: [p3])

        return AudiobookProject(
            id: ids.next(),
            metadata: BookMetadata(title: "Broken", author: "A", narrator: "N"),
            chapters: [ch1, ch2],
            createdAt: clock.now,
            modifiedAt: clock.now
        )
    }

    // MARK: - Helpers

    private static func makeChapter(
        ordinal: Int,
        title: String,
        paraCount: Int,
        role: ChapterRole,
        ids: SequentialIDGenerator,
        clock: FixedClock,
        recordedFraction: Double = 0,
        flaggedFraction: Double = 0
    ) -> ProductionChapter {
        let chapterID = ids.next()
        var paragraphs: [Paragraph] = []

        for i in 0..<paraCount {
            let pID = ids.next()
            let text = "Paragraph \(i + 1) of \(title). This is auto-generated text for testing purposes. It contains enough words to make a realistic length paragraph for the fixture."
            let hash = SHA256Hex.hex(Data(text.utf8))
            var takes: [Take] = []
            var selectedTakeID: UUID? = nil

            if SimplePRNG.nextDouble() < recordedFraction {
                let takeID = ids.next()
                let assetRef = AudioAssetReference(
                    sha256: SHA256Hex.hex(Data("\(title)-\(i)".utf8)),
                    relativePath: "Audio/Original/xx/yy/\(i).wav",
                    byteCount: 100_000,
                    contentType: "public.wav"
                )
                let take = Take(
                    id: takeID,
                    paragraphID: pID,
                    assetRef: assetRef,
                    origin: .recorded,
                    recordedAt: clock.now,
                    duration: 5.0,
                    format: AudioFormatDescription(sampleRate: 48_000, channels: 1, codec: "pcm_s24le"),
                    textHashAtRecording: hash
                )
                takes = [take]
                selectedTakeID = takeID
            }

            let reviewState: ReviewState = SimplePRNG.nextDouble() < flaggedFraction ? .flagged : .unreviewed

            paragraphs.append(Paragraph(
                id: pID,
                ordinal: i,
                text: text,
                textHash: hash,
                takes: takes,
                selectedTakeID: selectedTakeID,
                reviewState: reviewState
            ))
        }

        return ProductionChapter(id: chapterID, ordinal: ordinal, title: title, role: role, paragraphs: paragraphs)
    }
}
