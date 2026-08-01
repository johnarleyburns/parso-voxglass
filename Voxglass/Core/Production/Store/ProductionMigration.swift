import Foundation

public struct ProductionMigration: Sendable {
    public let id: Int
    public let name: String
    public let statements: [String]

    public init(id: Int, name: String, statements: [String]) {
        self.id = id
        self.name = name
        self.statements = statements
    }

    public static let all: [ProductionMigration] = [
        ProductionMigration(id: 1, name: "initial_production_schema", statements: schemaV1)
    ]

    static let schemaV1: [String] = [
        """
        CREATE TABLE project (
            id                  TEXT PRIMARY KEY NOT NULL,
            title               TEXT NOT NULL,
            subtitle            TEXT,
            author              TEXT NOT NULL,
            translator          TEXT,
            narrator            TEXT NOT NULL,
            language            TEXT NOT NULL DEFAULT 'en-US',
            description         TEXT NOT NULL DEFAULT '',
            subjects_json       TEXT NOT NULL DEFAULT '[]',
            series_name         TEXT,
            series_index        INTEGER,
            publisher           TEXT,
            copyright_year      INTEGER,
            production_year     INTEGER,
            rights_holder       TEXT,
            isbn                TEXT,
            asin                TEXT,
            is_abridged         INTEGER NOT NULL DEFAULT 0,
            cover_sha256        TEXT,
            archive_identifier  TEXT,
            purpose             TEXT NOT NULL,
            intended_destination TEXT NOT NULL,
            rights_basis        TEXT NOT NULL,
            rights_source_url   TEXT,
            rights_edition_year INTEGER,
            rights_notes        TEXT NOT NULL DEFAULT '',
            rights_attested_at  REAL,
            rights_attested_by  TEXT,
            rights_license_url  TEXT,
            recording_json      TEXT NOT NULL,
            assembly_json       TEXT NOT NULL,
            hidden_from_devices INTEGER NOT NULL DEFAULT 0,
            auto_sync_takes     INTEGER NOT NULL DEFAULT 1,
            include_source_text INTEGER NOT NULL DEFAULT 1,
            proxy_bitrate_kbps  INTEGER NOT NULL DEFAULT 80,
            source_json         TEXT,
            created_at          REAL NOT NULL,
            modified_at         REAL NOT NULL,
            schema_version      INTEGER NOT NULL,
            projection_revision INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE chapter (
            id            TEXT PRIMARY KEY NOT NULL,
            project_id    TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            ordinal       INTEGER NOT NULL,
            title         TEXT NOT NULL,
            role          TEXT NOT NULL DEFAULT 'body',
            head_silence  REAL,
            tail_silence  REAL,
            notes         TEXT,
            UNIQUE(project_id, ordinal)
        )
        """,
        """
        CREATE TABLE paragraph (
            id                TEXT PRIMARY KEY NOT NULL,
            chapter_id        TEXT NOT NULL REFERENCES chapter(id) ON DELETE CASCADE,
            project_id        TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            ordinal           INTEGER NOT NULL,
            text              TEXT NOT NULL,
            text_hash         TEXT NOT NULL,
            role              TEXT NOT NULL DEFAULT 'body',
            direction_note    TEXT,
            selected_take_id  TEXT,
            review_state      TEXT NOT NULL DEFAULT 'unreviewed',
            source_start      INTEGER,
            source_end        INTEGER,
            source_file_hash  TEXT,
            is_scene_break    INTEGER NOT NULL DEFAULT 0,
            updated_at        REAL NOT NULL,
            global_ordinal    INTEGER NOT NULL DEFAULT 0,
            UNIQUE(chapter_id, ordinal)
        )
        """,
        "CREATE INDEX idx_paragraph_project_state ON paragraph(project_id, review_state)",
        "CREATE INDEX idx_paragraph_chapter_ordinal ON paragraph(chapter_id, ordinal)",
        "CREATE INDEX idx_paragraph_selected ON paragraph(project_id, selected_take_id)",
        "CREATE INDEX idx_paragraph_global ON paragraph(project_id, global_ordinal)",
        """
        CREATE TABLE take (
            id                    TEXT PRIMARY KEY NOT NULL,
            paragraph_id          TEXT NOT NULL REFERENCES paragraph(id) ON DELETE CASCADE,
            project_id            TEXT NOT NULL,
            asset_sha256          TEXT NOT NULL,
            asset_path            TEXT NOT NULL,
            asset_bytes           INTEGER NOT NULL,
            asset_content_type    TEXT NOT NULL,
            origin_kind           TEXT NOT NULL,
            origin_payload        TEXT,
            recorded_at           REAL NOT NULL,
            duration              REAL NOT NULL,
            sample_rate           REAL NOT NULL,
            channels              INTEGER NOT NULL,
            bit_depth             INTEGER,
            codec                 TEXT NOT NULL,
            processing_json       TEXT NOT NULL DEFAULT '[]',
            metrics_json          TEXT,
            label                 TEXT,
            text_hash_at_recording TEXT NOT NULL,
            is_archived           INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX idx_take_paragraph ON take(paragraph_id)",
        "CREATE INDEX idx_take_origin ON take(project_id, origin_kind)",
        """
        CREATE TABLE pronunciation (
            id         TEXT PRIMARY KEY NOT NULL,
            project_id TEXT NOT NULL REFERENCES project(id) ON DELETE CASCADE,
            term       TEXT NOT NULL,
            guidance   TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE paragraph_pronunciation (
            paragraph_id     TEXT NOT NULL REFERENCES paragraph(id) ON DELETE CASCADE,
            pronunciation_id TEXT NOT NULL REFERENCES pronunciation(id) ON DELETE CASCADE,
            PRIMARY KEY (paragraph_id, pronunciation_id)
        )
        """,
        """
        CREATE TABLE review_note (
            id           TEXT PRIMARY KEY NOT NULL,
            project_id   TEXT NOT NULL,
            paragraph_id TEXT NOT NULL REFERENCES paragraph(id) ON DELETE CASCADE,
            text         TEXT NOT NULL,
            tag          TEXT,
            device       TEXT NOT NULL,
            timecode     REAL,
            created_at   REAL NOT NULL,
            resolved_at  REAL
        )
        """,
        "CREATE INDEX idx_note_paragraph ON review_note(paragraph_id)",
        """
        CREATE TABLE review_event (
            id           TEXT PRIMARY KEY NOT NULL,
            project_id   TEXT NOT NULL,
            paragraph_id TEXT NOT NULL,
            type         TEXT NOT NULL,
            note_text    TEXT,
            tag          TEXT,
            device       TEXT NOT NULL,
            created_at   REAL NOT NULL,
            applied_at   REAL,
            origin       TEXT NOT NULL DEFAULT 'local'
        )
        """,
        "CREATE INDEX idx_event_unapplied ON review_event(project_id, applied_at)",
        "CREATE INDEX idx_event_paragraph_time ON review_event(paragraph_id, created_at)",
        """
        CREATE TABLE render_cache (
            cache_key   TEXT PRIMARY KEY NOT NULL,
            chapter_id  TEXT NOT NULL,
            asset_sha256 TEXT NOT NULL,
            asset_path  TEXT NOT NULL,
            asset_bytes INTEGER NOT NULL,
            duration    REAL NOT NULL,
            created_at  REAL NOT NULL
        )
        """,
        """
        CREATE TABLE proxy_cache (
            take_id      TEXT PRIMARY KEY NOT NULL,
            asset_sha256 TEXT NOT NULL,
            asset_path   TEXT NOT NULL,
            asset_bytes  INTEGER NOT NULL,
            bitrate_kbps INTEGER NOT NULL,
            created_at   REAL NOT NULL
        )
        """,
        """
        CREATE TABLE sync_state (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT
        )
        """,
        """
        CREATE TABLE export_run (
            id             TEXT PRIMARY KEY NOT NULL,
            project_id     TEXT NOT NULL,
            destination    TEXT NOT NULL,
            started_at     REAL NOT NULL,
            finished_at    REAL,
            output_path    TEXT,
            status         TEXT NOT NULL,
            error_code     TEXT,
            file_count     INTEGER,
            total_bytes    INTEGER,
            report_json    TEXT
        )
        """
    ]
}
