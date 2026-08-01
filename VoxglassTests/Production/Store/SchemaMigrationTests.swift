import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct SchemaMigrationTests {

    @Test func migration1CreatesAllTables() async throws {
        let db = ProjectDatabase.makeTemporary(named: "migration1")
        try await db.prepare()

        let expectedTables: Set<String> = [
            "schema_migrations", "project", "chapter", "paragraph",
            "take", "pronunciation", "paragraph_pronunciation",
            "review_note", "review_event", "render_cache",
            "proxy_cache", "sync_state", "export_run"
        ]

        let rows = try await db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        let actualTables = Set(rows.compactMap { $0.string("name") })

        for table in expectedTables {
            #expect(actualTables.contains(table), "Table \(table) should exist")
        }
    }

    /// Spec §7.4 rule 4: the captured `v1.sql` snapshot must build a database
    /// whose schema matches the current migration list exactly. This is the
    /// drift guard that keeps the snapshot trustworthy for future migrations.
    @Test func capturedV1SnapshotMatchesMigration1() async throws {
        let snapshotSQL = try SchemaFixtures.v1SQL()

        // Build the old schema purely from the captured snapshot (no
        // migrations, no schema_migrations bookkeeping).
        let snapshotDB = ProjectDatabase.makeTemporary(named: "snapshot_v1")
        try await snapshotDB.open()
        try await snapshotDB.executeRaw(snapshotSQL)

        // Build the current schema via the migration runner.
        let migratedDB = ProjectDatabase.makeTemporary(named: "migrated_v1")
        try await migratedDB.prepare()

        let snapshotSchema = try await sqliteMaster(from: snapshotDB)
        let migratedSchema = try await sqliteMaster(from: migratedDB)
        // The migration runner adds schema_migrations bookkeeping that the
        // captured snapshot (correctly) does not contain; compare the rest,
        // ignoring whitespace-only differences in the DDL text.
        func normalized(_ entries: [String]) -> [String] {
            entries
                .filter { !$0.contains("schema_migrations") }
                .map { entry in
                    entry.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
        }
        #expect(normalized(snapshotSchema) == normalized(migratedSchema),
            "v1.sql snapshot drifted from ProductionMigration.schemaV1")
    }

    /// §7.4 rule 4, forward direction: a database built from the v1 snapshot
    /// and stamped as migrated must open cleanly (no re-run of migration 1).
    @Test func snapshotDatabaseOpensCleanlyWhenStamped() async throws {
        let snapshotSQL = try SchemaFixtures.v1SQL()

        let db = ProjectDatabase.makeTemporary(named: "snapshot_stamped")
        try await db.open()
        try await db.executeRaw(snapshotSQL)
        // Stamp the schema_migrations bookkeeping as if v1 was applied.
        try await db.executeRaw("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at REAL NOT NULL
        )
        """)
        try await db.executeRaw("INSERT INTO schema_migrations (id, name, applied_at) VALUES (1, 'initial_production_schema', 0)")

        // prepare() must be a no-op, not a schema conflict.
        try await db.prepare()

        let rows = try await db.query("SELECT COUNT(*) AS cnt FROM schema_migrations")
        #expect(Int(rows.first?.int("cnt") ?? 0) == 1)
    }

    private func sqliteMaster(from db: ProjectDatabase) async throws -> [String] {
        let rows = try await db.queryRaw("SELECT type, name, sql FROM sqlite_master ORDER BY type, name")
        return rows.compactMap { row -> String? in
            let sql = row.string("sql") ?? ""
            return "\(row.string("type") ?? "")|\(row.string("name") ?? "")|\(sql)"
        }
    }

    @Test func migrationDoesNotRunTwice() async throws {
        let db = ProjectDatabase.makeTemporary(named: "migration_idempotent")
        try await db.prepare()

        let countRows = try await db.query("SELECT COUNT(*) AS cnt FROM schema_migrations")
        let firstRun = Int(countRows.first?.int("cnt") ?? 0)

        try await db.prepare()

        let countRows2 = try await db.query("SELECT COUNT(*) AS cnt FROM schema_migrations")
        let secondRun = Int(countRows2.first?.int("cnt") ?? 0)

        #expect(firstRun == secondRun)
        #expect(firstRun > 0)
    }

    @Test func canInsertAndQueryProject() async throws {
        let db = ProjectDatabase.makeTemporary(named: "insert_project")
        try await db.prepare()

        let id = UUID().uuidString
        try await db.execute("""
            INSERT INTO project (id, title, author, narrator, purpose, intended_destination, rights_basis, recording_json, assembly_json, created_at, modified_at, schema_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.string(id), .string("Test"), .string("Author"), .string("Narrator"),
                  .string("publicDomainCommunity"), .string("librivox"), .string("publicDomainUS"),
                  .string("{}"), .string("{}"), .double(Date().timeIntervalSince1970),
                  .double(Date().timeIntervalSince1970), .int(1)])

        let rows = try await db.query("SELECT * FROM project WHERE id = ?", [.string(id)])
        #expect(rows.count == 1)
        #expect(rows[0].string("title") == "Test")
    }

    @Test func transactionRollsBackOnError() async throws {
        let db = ProjectDatabase.makeTemporary(named: "rollback")
        try await db.prepare()

        do {
            try await db.transaction { db in
                try await db.execute("INSERT INTO project (id,title,author,narrator,purpose,intended_destination,rights_basis,recording_json,assembly_json,created_at,modified_at,schema_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                    [.string(UUID().uuidString), .string("R"), .string("A"), .string("N"),
                     .string("publicDomainCommunity"), .string("librivox"), .string("publicDomainUS"),
                     .string("{}"), .string("{}"), .double(0), .double(0), .int(1)])
                throw StoreError.busy
            }
        } catch {}

        let rows = try await db.query("SELECT COUNT(*) AS cnt FROM project")
        #expect(Int(rows.first?.int("cnt") ?? 0) == 0)
    }
}
