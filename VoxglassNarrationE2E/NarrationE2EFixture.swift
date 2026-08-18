import Foundation
import VoxglassCore
@testable import Voxglass

enum NarrationE2EFixture {
    @MainActor
    static func seed(into repository: NarrationProjectRepository) async throws -> AudiobookProject {
        let chapters: [(String, [String])] = [
            ("The Lion and the Mouse", [
                "A lion lay asleep in the forest when a little mouse ran across his paw and woke him from a pleasant afternoon dream.",
                "The lion caught the mouse beneath one great paw, but the frightened creature begged for mercy and promised to repay the kindness.",
                "Later, hunters trapped the lion in a strong net, and his roaring carried through the trees until the mouse heard his old friend.",
                "The mouse gnawed through the ropes and set the lion free, proving that no kindness is wasted and even the small may help the great."
            ]),
            ("The Tortoise and the Hare", [
                "A swift hare laughed at a tortoise for moving slowly, so the tortoise calmly challenged the boastful animal to a race across the meadow.",
                "The hare rushed far ahead and, certain of victory, settled beneath a shady tree to rest while the tortoise continued at an even pace.",
                "The hare slept longer than he intended, and the tortoise passed quietly by without stopping or turning aside from the marked course.",
                "When the hare finally awoke, he ran with all his speed but found the tortoise already at the finish, rewarded for steady effort."
            ]),
            ("The Fox and the Grapes", [
                "One warm afternoon a hungry fox discovered a vine heavy with ripe purple grapes hanging from a branch just beyond his reach.",
                "He jumped again and again, first from one side and then the other, but every leap ended with the tempting fruit untouched.",
                "Tired and embarrassed, the fox walked away while telling himself that the grapes were surely sour and not worth eating after all.",
                "It is easy to despise what we cannot obtain, though honest disappointment would teach us more than a proud excuse ever could."
            ])
        ]
        let sections = chapters.map { title, paragraphs in
            ExtractedSection(
                heading: title,
                blocks: paragraphs.map { text in
                    ExtractedBlock(kind: .paragraph, text: text, sourceRange: 0..<text.utf8.count)
                }
            )
        }
        let document = ExtractedDocument(
            sections: sections,
            title: "Three Fables",
            author: "Aesop",
            language: "en-US",
            plainText: chapters.flatMap { $0.1 }.joined(separator: "\n\n")
        )
        var project = NarrationProjectBuilder().build(
            document: document,
            title: "Three Fables",
            author: "Aesop",
            narrator: "Voxglass Test Reader",
            sourceURL: URL(string: "https://www.gutenberg.org/ebooks/21"),
            purpose: .personal,
            ids: repository.ids,
            clock: repository.clock
        ).project
        project.profile.assembly = AssemblySettings(
            paragraphGap: 0,
            chapterHeadSilence: 0,
            chapterTailSilence: 0,
            sceneBreakExtraGap: 0,
            normalizeGapsFromTakeSilence: false,
            trimSilenceAtEdges: false,
            normalizeLoudness: false
        )
        try await repository.save(project)
        return project
    }
}

final class NarrationE2EIDGenerator: IDGenerator, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func next() -> UUID {
        lock.withLock {
            defer { value += 1 }
            return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
        }
    }
}

struct NarrationE2EClock: Clock {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
}
