import Foundation

/// Wire protocol version for complete editable Voxglass authoring state.
public enum AuthoringProtocol {
    public static let version = 2
    public static let zoneName = "VGStudioAuthoringV2"
}

/// JSON values used by extensible v2 records. Unrecognized values remain intact
/// when a client reads and writes a record written by a newer device.
public enum AuthoringValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([AuthoringValue])
    case object([String: AuthoringValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if try value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([AuthoringValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: AuthoringValue].self) { self = .object(object) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported authoring value") }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
}

/// A partial update distinguishes an absent field from an explicit clear.
public enum AuthoringPatch<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case missing
    case clear
    case set(Value)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if try container.decodeNil() { self = .clear }
        else { self = .set(try container.decode(Value.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .missing, .clear: try container.encodeNil()
        case .set(let value): try container.encode(value)
        }
    }
}

public extension KeyedDecodingContainer {
    /// Decodes partial updates without collapsing an absent key into an explicit null.
    func decodePatch<Value: Codable & Sendable & Equatable>(
        _ type: Value.Type, forKey key: Key
    ) throws -> AuthoringPatch<Value> {
        guard contains(key) else { return .missing }
        if try decodeNil(forKey: key) { return .clear }
        return .set(try decode(Value.self, forKey: key))
    }
}

public extension KeyedEncodingContainer {
    /// Omits `.missing`, writes JSON null for `.clear`, and writes `.set` values.
    mutating func encodePatch<Value: Codable & Sendable & Equatable>(
        _ patch: AuthoringPatch<Value>, forKey key: Key
    ) throws {
        switch patch {
        case .missing: break
        case .clear: try encodeNil(forKey: key)
        case .set(let value): try encode(value, forKey: key)
        }
    }
}

/// Project metadata stored in the portable authoring-v2 wire format.
public struct AuthoringProject: Codable, Sendable, Equatable {
    public var protocolVersion: UInt32
    public var id: UUID
    public var title: String
    public var metadata: [String: AuthoringValue]
    public var sourceIds: [UUID]
    public var capabilityFlags: [String]
    public var modifiedAt: String
    public var extensions: [String: AuthoringValue]

    public init(
        protocolVersion: UInt32 = UInt32(AuthoringProtocol.version), id: UUID, title: String,
        metadata: [String: AuthoringValue] = [:], sourceIds: [UUID] = [],
        capabilityFlags: [String] = [], modifiedAt: String, extensions: [String: AuthoringValue] = [:]
    ) {
        self.protocolVersion = protocolVersion; self.id = id; self.title = title
        self.metadata = metadata; self.sourceIds = sourceIds; self.capabilityFlags = capabilityFlags
        self.modifiedAt = modifiedAt; self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case protocolVersion, id, title, metadata, sourceIds, capabilityFlags, modifiedAt }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(UInt32.self, forKey: .protocolVersion)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        metadata = try container.decodeIfPresent([String: AuthoringValue].self, forKey: .metadata) ?? [:]
        sourceIds = try container.decodeIfPresent([UUID].self, forKey: .sourceIds) ?? []
        capabilityFlags = try container.decodeIfPresent([String].self, forKey: .capabilityFlags) ?? []
        modifiedAt = try container.decode(String.self, forKey: .modifiedAt)
        let object = try decoder.container(keyedBy: AuthoringDynamicKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        extensions = try Dictionary(uniqueKeysWithValues: object.allKeys.filter { !known.contains($0.stringValue) }.map {
            ($0.stringValue, try object.decode(AuthoringValue.self, forKey: $0))
        })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(sourceIds, forKey: .sourceIds)
        try container.encode(capabilityFlags, forKey: .capabilityFlags)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        var dynamic = encoder.container(keyedBy: AuthoringDynamicKey.self)
        for (key, value) in extensions {
            guard let codingKey = AuthoringDynamicKey(stringValue: key) else { continue }
            try dynamic.encode(value, forKey: codingKey)
        }
    }
}

public struct AuthoringDynamicKey: CodingKey, Sendable, Hashable {
    public var stringValue: String
    public init?(stringValue: String) { self.stringValue = stringValue }
    public var intValue: Int? { nil }
    public init?(intValue: Int) { return nil }
}

/// A chapter keeps its time values as integer samples with an explicit rate.
public struct AuthoringChapter: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectId: UUID
    public var ordinal: UInt32
    public var title: String
    public var role: String
    public var headGapFrames: UInt64
    public var tailGapFrames: UInt64
    public var sampleRate: UInt32
    public var extensions: [String: AuthoringValue]
}

/// A paragraph's text, source position, and selected-take pointer are separate mutable fields.
public struct AuthoringParagraph: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectId: UUID
    public var chapterId: UUID
    public var ordinal: UInt32
    public var text: String
    public var textSha256: String
    public var direction: String?
    public var sourceRange: AuthoringSourceRange?
    public var pronunciationIds: [UUID]
    public var selectedTakeId: UUID?
    public var selectionRevision: String
    public var extensions: [String: AuthoringValue]
}

public struct AuthoringSourceRange: Codable, Sendable, Equatable {
    public var sourceId: UUID
    public var startUtf8: UInt64
    public var endUtf8: UInt64
}

/// Immutable capture identity; label, archive state, and processing live in `AuthoringTakeState`.
public struct AuthoringTakeCapture: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectId: UUID
    public var paragraphId: UUID
    public var capturedAt: String
    public var origin: String
    public var recordedTextSha256: String
    public var sampleRate: UInt32
    public var channels: UInt16
    public var bitsPerSample: UInt16?
    public var codec: String
    public var frameCount: UInt64
    public var warning: String?
    public var assetManifestId: UUID
    public var extensions: [String: AuthoringValue]
}

/// Mutable state is versioned separately from the immutable media capture.
public struct AuthoringTakeState: Codable, Sendable, Equatable {
    public var takeId: UUID
    public var label: String?
    public var archived: Bool
    public var recipe: [AuthoringProcessingStep]
    public var recipeRevision: String
    public var extensions: [String: AuthoringValue]
}

public struct AuthoringProcessingStep: Codable, Sendable, Equatable {
    public var kind: String
    public var parameters: [String: Double]
}

public struct AuthoringAssetManifest: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectId: UUID
    public var role: String
    public var byteLength: UInt64
    public var sha256: String
    public var chunks: [AuthoringAssetChunk]
    public var contentType: String
    public var extensions: [String: AuthoringValue]
}

public struct AuthoringAssetChunk: Codable, Sendable, Equatable {
    public var ordinal: UInt32
    public var byteLength: UInt64
    public var sha256: String
    public var recordId: String
}

/// Review is historical and binds to the exact text/take/recipe basis reviewed.
public struct AuthoringReviewEvent: Codable, Sendable, Equatable {
    public var id: UUID
    public var projectId: UUID
    public var paragraphId: UUID
    public var takeId: UUID?
    public var action: String
    public var textRevision: String
    public var recipeRevision: String?
    public var note: String?
    public var createdAt: String
    public var extensions: [String: AuthoringValue]
}

public struct AuthoringMutationReceipt: Codable, Sendable, Equatable {
    public var operationId: UUID
    public var entityId: UUID
    public var payloadSha256: String
    public var acceptedAt: String
}

public struct AuthoringConflictCandidate: Codable, Sendable, Equatable {
    public var id: UUID
    public var entityId: UUID
    public var field: String
    public var localValue: AuthoringValue
    public var remoteValue: AuthoringValue
    public var baseValue: AuthoringValue?
}

public struct AuthoringTombstone: Codable, Sendable, Equatable {
    public var operationId: UUID
    public var entityId: UUID
    public var entityKind: String
    public var deletedAt: String
}
