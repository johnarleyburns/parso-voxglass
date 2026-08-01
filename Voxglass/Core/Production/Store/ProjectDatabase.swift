import Foundation
import SQLite3

public actor ProjectDatabase {
    public nonisolated let url: URL
    private let clock: any Clock
    private var handle: OpaquePointer?
    private var didMigrate = false

    public init(url: URL, clock: any Clock = SystemClock()) {
        self.url = url
        self.clock = clock
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    public static func makeTemporary(named name: String = UUID().uuidString) -> ProjectDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxglassProductionTests", isDirectory: true)
            .appendingPathComponent("\(name).sqlite")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        return ProjectDatabase(url: url)
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

    public func transaction<T>(_ body: (ProjectDatabase) async throws -> T) async throws -> T {
        try prepare()
        try executeRaw("BEGIN IMMEDIATE TRANSACTION")
        do {
            let result = try await body(self)
            try executeRaw("COMMIT")
            return result
        } catch {
            try? executeRaw("ROLLBACK")
            throw error
        }
    }

    public func vacuum() throws {
        try executeRaw("VACUUM")
    }

    public func checkpoint() throws {
        try executeRaw("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Opens the database and applies PRAGMAs without running migrations.
    /// Public so migration tests can build an *old* schema from a captured
    /// DDL snapshot (spec §7.4 rule 4) and then observe migrations upgrade it.
    public func open() throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw DatabaseError.openFailed(message)
        }
        handle = database

        try executeRaw("PRAGMA journal_mode = WAL")
        try executeRaw("PRAGMA synchronous = NORMAL")
        try executeRaw("PRAGMA foreign_keys = ON")
        try executeRaw("PRAGMA busy_timeout = 5000")
        try executeRaw("PRAGMA temp_store = MEMORY")
        try executeRaw("PRAGMA cache_size = -20000")
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

    public func migrate() throws {
        try executeRaw("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at REAL NOT NULL
        )
        """)

        let applied = try queryRaw("SELECT id FROM schema_migrations")
            .compactMap { $0.int("id") }
            .map(Int.init)
        let appliedSet = Set(applied)

        for migration in ProductionMigration.all where !appliedSet.contains(migration.id) {
            try executeRaw("BEGIN IMMEDIATE TRANSACTION")
            do {
                for statement in migration.statements {
                    try executeRaw(statement)
                }
                try executeRaw("""
                INSERT INTO schema_migrations (id, name, applied_at)
                VALUES (\(migration.id), '\(migration.name)', \(clock.now.timeIntervalSince1970))
                """)
                try executeRaw("COMMIT")
            } catch {
                try? executeRaw("ROLLBACK")
                throw error
            }
        }
    }

    /// Runs a query on the already-open database without triggering
    /// migrations. Public so migration tests can inspect a schema built from
    /// a captured snapshot (spec §7.4 rule 4).
    public func queryRaw(_ sql: String) throws -> [DatabaseRow] {
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }

        var rows: [DatabaseRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(row(from: statement))
        }
        return rows
    }

    private var lastErrorMessage: String {
        guard let handle else { return "database is not open" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
