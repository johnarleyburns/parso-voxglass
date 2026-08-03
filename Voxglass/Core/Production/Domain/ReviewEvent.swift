import Foundation

public struct ReviewEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var projectID: UUID
    public var paragraphID: UUID
    public var type: ReviewEventType
    public var noteText: String?
    public var tag: ReviewTag?
    public var device: DeviceKind
    public var createdAt: Date
    public var appliedAt: Date?
    public var origin: Origin

    public enum Origin: String, Codable, Sendable { case local, cloud }

    public init(
        id: UUID = UUID(), // determinism-exempt: convenience default for new events; sync paths pass SequentialIDGenerator values
        projectID: UUID,
        paragraphID: UUID,
        type: ReviewEventType,
        noteText: String? = nil,
        tag: ReviewTag? = nil,
        device: DeviceKind,
        createdAt: Date = Date(), // determinism-exempt: convenience default for new events; sync paths pass Clock values
        appliedAt: Date? = nil,
        origin: Origin = .local
    ) {
        self.id = id
        self.projectID = projectID
        self.paragraphID = paragraphID
        self.type = type
        self.noteText = noteText
        self.tag = tag
        self.device = device
        self.createdAt = createdAt
        self.appliedAt = appliedAt
        self.origin = origin
    }
}

public enum ReviewEventType: String, Codable, Sendable {
    case flag, unflag, approve, needsPickup, clearPickup, addNote, voiceNoteRequested, resolveNote
}
