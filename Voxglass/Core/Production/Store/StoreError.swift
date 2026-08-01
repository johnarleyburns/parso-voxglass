import Foundation

public enum StoreError: VoxglassError {
    case migrationFailed(Int, String)
    case constraintViolation(String)
    case notFound(UUID)
    case projectNotFound
    case corruptRow(String)
    case busy

    public var code: String {
        switch self {
        case .migrationFailed: "STORE.MIGRATION_FAILED"
        case .constraintViolation: "STORE.CONSTRAINT_VIOLATION"
        case .notFound: "STORE.NOT_FOUND"
        case .projectNotFound: "STORE.PROJECT_NOT_FOUND"
        case .corruptRow: "STORE.CORRUPT_ROW"
        case .busy: "STORE.BUSY"
        }
    }

    public var userMessage: String {
        switch self {
        case .migrationFailed(let id, let detail): "Database migration \(id) failed: \(detail)"
        case .constraintViolation(let detail): "Database constraint violation: \(detail)"
        case .notFound(let id): "Record not found: \(id)"
        case .projectNotFound: "No project exists in this store yet."
        case .corruptRow(let detail): "Corrupt database row: \(detail)"
        case .busy: "The database is busy. Please try again."
        }
    }

    public var isRecoverable: Bool {
        switch self {
        case .busy: true
        default: false
        }
    }

    public var underlying: (any Error)? { nil }
}
