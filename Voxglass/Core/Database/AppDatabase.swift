import Foundation
import SQLite3

public actor AppDatabase {
    private let url: URL
    private var handle: OpaquePointer?
    private var didMigrate = false

    public init(url: URL) {
        self.url = url
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    public static func makeApplicationDatabase() -> AppDatabase {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Voxglass", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return AppDatabase(url: directory.appendingPathComponent("voxglass.sqlite"))
        } catch {
            return AppDatabase(url: FileManager.default.temporaryDirectory.appendingPathComponent("voxglass.sqlite"))
        }
    }

    public static func makeTemporaryDatabase(named name: String = UUID().uuidString) -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxglassTests", isDirectory: true)
            .appendingPathComponent("\(name).sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        return AppDatabase(url: url)
    }

    public func prepare() throws {
        if handle == nil {
            try open()
        }
        if !didMigrate {
            try migrate()
            didMigrate = true
        }
    }

    public func execute(_ sql: String, _ bindings: [DatabaseValue] = []) throws {
        try prepare()
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage)
        }
    }

    public func query(_ sql: String, _ bindings: [DatabaseValue] = []) throws -> [DatabaseRow] {
        try prepare()
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [DatabaseRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(row(from: statement))
        }
        return rows
    }

    /// Runs every statement inside one BEGIN IMMEDIATE…COMMIT transaction in a
    /// single actor hop, so no other database call — and no reentrant read on a
    /// calling actor — can interleave mid-transaction.
    public func executeBatch(_ statements: [(sql: String, bindings: [DatabaseValue])]) throws {
        try prepare()
        try executeRaw("BEGIN IMMEDIATE TRANSACTION")
        do {
            for statement in statements {
                let prepared = try prepareStatement(statement.sql)
                defer { sqlite3_finalize(prepared) }
                try bind(statement.bindings, to: prepared)
                guard sqlite3_step(prepared) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(lastErrorMessage)
                }
            }
            try executeRaw("COMMIT")
        } catch {
            try? executeRaw("ROLLBACK")
            throw error
        }
    }

    private func open() throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw DatabaseError.openFailed(message)
        }
        handle = database
        try executeRaw("PRAGMA foreign_keys = ON")
        try executeRaw("PRAGMA journal_mode = WAL")
    }

    public func executeRaw(_ sql: String) throws {
        guard let handle else { throw DatabaseError.openFailed("database is not open") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(error)
            throw DatabaseError.stepFailed(message)
        }
    }

    public func prepareStatement(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw DatabaseError.openFailed("database is not open") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepareFailed(lastErrorMessage)
        }
        return statement
    }

    private func bind(_ values: [DatabaseValue], to statement: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .int(let int):
                result = sqlite3_bind_int64(statement, position, int)
            case .double(let double):
                result = sqlite3_bind_double(statement, position, double)
            case .string(let string):
                result = sqlite3_bind_text(statement, position, string, -1, sqliteTransient)
            case .bool(let bool):
                result = sqlite3_bind_int64(statement, position, bool ? 1 : 0)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.bindFailed(lastErrorMessage)
            }
        }
    }

    public func row(from statement: OpaquePointer) -> DatabaseRow {
        let count = sqlite3_column_count(statement)
        var values: [String: DatabaseValue] = [:]

        for index in 0..<count {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT:
                values[name] = .double(sqlite3_column_double(statement, index))
            case SQLITE_TEXT:
                values[name] = .string(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_NULL:
                values[name] = .null
            default:
                values[name] = .null
            }
        }

        return DatabaseRow(values: values)
    }

    private var lastErrorMessage: String {
        guard let handle else { return "database is not open" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
