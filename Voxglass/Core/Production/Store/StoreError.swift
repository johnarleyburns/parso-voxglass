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
        case .migrationFailed(let id, let detail): String(localized: "Database migration \(id) failed: \(detail)", bundle: .module)
        case .constraintViolation(let detail): String(localized: "Database constraint violation: \(detail)", bundle: .module)
        case .notFound(let id): String(localized: "Record not found: \(id.uuidString)", bundle: .module)
        case .projectNotFound: String(localized: "No project exists in this store yet.", bundle: .module)
        case .corruptRow(let detail): String(localized: "Corrupt database row: \(detail)", bundle: .module)
        case .busy: String(localized: "The database is busy. Please try again.", bundle: .module)
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
