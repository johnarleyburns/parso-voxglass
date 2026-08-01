import Foundation

public enum NarrationOrigin: String, Codable, Sendable { case humanOnly, containsImportedAI }

public struct EligibilityProfile: Sendable, Equatable, Codable {
    public let narrationOrigin: NarrationOrigin
    public let librivoxEligible: Bool
    public let aiParagraphIDs: [UUID]
    public let humanParagraphCount: Int
    public let aiParagraphCount: Int

    private init(origin: NarrationOrigin, aiIDs: [UUID], human: Int, ai: Int) {
        self.narrationOrigin = origin
        self.librivoxEligible = (origin == .humanOnly)
        self.aiParagraphIDs = aiIDs
        self.humanParagraphCount = human
        self.aiParagraphCount = ai
    }

    public static func evaluate(_ project: AudiobookProject) -> EligibilityProfile {
        var aiIDs: [UUID] = []
        var human = 0
        var ai = 0
        for p in project.allParagraphs {
            guard let sel = p.selectedTakeID, let take = p.takes.first(where: { $0.id == sel }) else { continue }
            if take.origin.isHumanNarration { human += 1 } else { ai += 1; aiIDs.append(p.id) }
        }
        return EligibilityProfile(
            origin: ai > 0 ? .containsImportedAI : .humanOnly,
            aiIDs: aiIDs,
            human: human,
            ai: ai
        )
    }
}
