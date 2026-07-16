import Foundation

public enum DatabaseValue: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "1" : "0"
        case .null: nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): value
        case .bool(let value): value ? 1 : 0
        case .string(let value): Int64(value)
        case .double(let value): Int64(value)
        case .null: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        case .bool(let value): value ? 1 : 0
        case .string(let value): Double(value)
        case .null: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .int(let value): value != 0
        case .double(let value): value != 0
        case .string(let value): ["1", "true", "yes"].contains(value.lowercased())
        case .null: nil
        }
    }
}

public struct DatabaseRow {
    public let values: [String: DatabaseValue]

    public func string(_ column: String) -> String? {
        values[column]?.stringValue
    }

    public func requiredString(_ column: String) throws -> String {
        guard let value = string(column) else {
            throw DatabaseError.missingColumn(column)
        }
        return value
    }

    public func int(_ column: String) -> Int64? {
        values[column]?.intValue
    }

    public func double(_ column: String) -> Double? {
        values[column]?.doubleValue
    }

    public func bool(_ column: String) -> Bool? {
        values[column]?.boolValue
    }
}

public enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case missingColumn(String)
    case invalidUUID(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open database: \(message)"
        case .prepareFailed(let message): "Could not prepare SQL statement: \(message)"
        case .stepFailed(let message): "Could not execute SQL statement: \(message)"
        case .bindFailed(let message): "Could not bind SQL value: \(message)"
        case .missingColumn(let column): "Missing database column: \(column)"
        case .invalidUUID(let value): "Invalid UUID in database: \(value)"
        }
    }
}

