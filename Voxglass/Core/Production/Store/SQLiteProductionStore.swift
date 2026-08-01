import Foundation

public final class SQLiteProductionStore: @unchecked Sendable, ProductionStore {
    private let db: ProjectDatabase
    private let clock: any Clock
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    public let databaseURL: URL

    public init(databaseURL: URL, clock: any Clock = SystemClock()) {
        self.databaseURL = databaseURL
        self.clock = clock
        self.db = ProjectDatabase(url: databaseURL, clock: clock)
    }

    public func load() async throws -> AudiobookProject {
        try await db.prepare()

        let projRows = try await db.query("SELECT * FROM project LIMIT 1")
        guard let projRow = projRows.first else { throw StoreError.projectNotFound }
        let projID = try uuid(from: projRow, column: "id")
        let project = try await loadProject(from: projRow)

        let chRows = try await db.query("SELECT * FROM chapter WHERE project_id = ? ORDER BY ordinal",
            [.string(projID.uuidString)])
        var chapters: [ProductionChapter] = []
        var chIdx: [UUID: Int] = [:]
        for chRow in chRows {
            chapters.append(try await loadChapter(from: chRow))
            chIdx[chapters.last!.id] = chapters.count - 1
        }

        let paraRows = try await db.query("SELECT * FROM paragraph WHERE project_id = ? ORDER BY global_ordinal",
            [.string(projID.uuidString)])
        let takeRows = try await db.query("SELECT * FROM take WHERE project_id = ?", [.string(projID.uuidString)])
        var takesByPara: [UUID: [Take]] = [:]
        for tRow in takeRows {
            let pid = try uuid(from: tRow, column: "paragraph_id")
            let take = try await loadTake(from: tRow)
            takesByPara[pid, default: []].append(take)
        }

        for pRow in paraRows {
            let pid = try uuid(from: pRow, column: "id")
            let cid = try uuid(from: pRow, column: "chapter_id")
            let selID: UUID? = pRow.string("selected_take_id").flatMap(UUID.init(uuidString:))
            var paraTakes = takesByPara[pid] ?? []
            if let sid = selID, let idx = paraTakes.firstIndex(where: { $0.id == sid }) {
                let selected = paraTakes.remove(at: idx)
                paraTakes.append(selected)
            }
            var para = try loadParagraph(from: pRow)
            para.takes = paraTakes
            para.selectedTakeID = selID
            if let idx = chIdx[cid] { chapters[idx].paragraphs.append(para) }
        }

        var result = project
        result.chapters = chapters
        return result
    }

    public func save(_ project: AudiobookProject) async throws {
        try await db.prepare()
        try await db.transaction { db in
            try await db.execute("DELETE FROM paragraph_pronunciation WHERE paragraph_id IN (SELECT id FROM paragraph WHERE project_id = ?)", [.string(project.id.uuidString)])
            try await db.execute("DELETE FROM take WHERE project_id = ?", [.string(project.id.uuidString)])
            try await db.execute("DELETE FROM paragraph WHERE project_id = ?", [.string(project.id.uuidString)])
            try await db.execute("DELETE FROM chapter WHERE project_id = ?", [.string(project.id.uuidString)])
            try await db.execute("DELETE FROM project WHERE id = ?", [.string(project.id.uuidString)])
            try await saveProject(db, project)
            for ch in project.chapters {
                try await saveChapter(db, ch, projectID: project.id)
                for para in ch.paragraphs {
                    try await saveParagraph(db, para, chapterID: ch.id, projectID: project.id)
                    for take in para.takes {
                        try await saveTake(db, take, paragraphID: para.id, projectID: project.id)
                    }
                }
            }
        }
        try await db.checkpoint()
    }

    public func summary() async throws -> ProjectSummary {
        try await db.prepare()
        let cc = try await counts()
        let rows = try await db.query("SELECT id, title, author, narrator, purpose, modified_at, hidden_from_devices FROM project LIMIT 1")
        guard let row = rows.first else { throw StoreError.projectNotFound }
        return ProjectSummary(
            id: try uuid(from: row, column: "id"),
            title: row.string("title") ?? "", author: row.string("author") ?? "",
            narrator: row.string("narrator") ?? "",
            percentRecorded: cc.paragraphs > 0 ? Double(cc.recorded) / Double(cc.paragraphs) : 0,
            recordedCount: cc.recorded, totalCount: cc.paragraphs,
            flaggedCount: cc.flagged, needsPickupCount: cc.needsPickup,
            purpose: ProjectPurpose(rawValue: row.string("purpose") ?? "publicDomainCommunity") ?? .publicDomainCommunity,
            modifiedAt: Date(timeIntervalSince1970: row.double("modified_at") ?? 0),
            isHiddenFromDevices: row.bool("hidden_from_devices") ?? false
        )
    }

    public func upsertChapter(_ chapter: ProductionChapter) async throws {
        try await db.prepare()
        try await db.execute("""
            INSERT INTO chapter (id, project_id, ordinal, title, role, head_silence, tail_silence, notes)
            VALUES (?, COALESCE((SELECT project_id FROM chapter WHERE id = ?), (SELECT id FROM project LIMIT 1)), ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                role = excluded.role,
                head_silence = excluded.head_silence,
                tail_silence = excluded.tail_silence,
                notes = excluded.notes
            """, [
            .string(chapter.id.uuidString), .string(chapter.id.uuidString),
            .int(Int64(chapter.ordinal)), .string(chapter.title),
            .string(chapter.role.rawValue),
            chapter.headSilenceOverride.map{.double($0)} ?? .null,
            chapter.tailSilenceOverride.map{.double($0)} ?? .null,
            chapter.notes.map{.string($0)} ?? .null,
        ])
    }

    public func upsertParagraph(_ paragraph: Paragraph) async throws {
        try await db.prepare()
        let sfh: DatabaseValue = (paragraph.sourceRange?.sourceFileHash).flatMap { $0.isEmpty ? nil : DatabaseValue.string($0) } ?? .null
        let sourceStart: DatabaseValue = paragraph.sourceRange.map{.int(Int64($0.startOffset))} ?? .null
        let sourceEnd: DatabaseValue = paragraph.sourceRange.map{.int(Int64($0.endOffset))} ?? .null
        try await db.execute("""
            INSERT INTO paragraph (id, chapter_id, project_id, ordinal, text, text_hash, role, direction_note, selected_take_id, review_state, source_start, source_end, source_file_hash, is_scene_break, updated_at, global_ordinal)
            VALUES (?,
                COALESCE((SELECT chapter_id FROM paragraph WHERE id = ?), ''),
                COALESCE((SELECT project_id FROM paragraph WHERE id = ?), (SELECT id FROM project LIMIT 1)),
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?, ?, ?,
                (SELECT COALESCE(MAX(global_ordinal), 0) + 1 FROM paragraph))
            ON CONFLICT(id) DO UPDATE SET
                text = excluded.text,
                text_hash = excluded.text_hash,
                role = excluded.role,
                direction_note = excluded.direction_note,
                selected_take_id = excluded.selected_take_id,
                review_state = excluded.review_state,
                source_start = excluded.source_start,
                source_end = excluded.source_end,
                source_file_hash = excluded.source_file_hash,
                is_scene_break = excluded.is_scene_break,
                updated_at = excluded.updated_at
            """, [
            .string(paragraph.id.uuidString),
            .string(paragraph.id.uuidString),
            .string(paragraph.id.uuidString),
            .int(Int64(paragraph.ordinal)), .string(paragraph.text), .string(paragraph.textHash),
            .string(paragraph.role.rawValue),
            paragraph.directionNote.map{.string($0)} ?? .null,
            paragraph.selectedTakeID.map{.string($0.uuidString)} ?? .null,
            .string(paragraph.reviewState.rawValue),
            sourceStart, sourceEnd, sfh,
            .bool(paragraph.isSceneBreak),
            .double(paragraph.updatedAt.timeIntervalSince1970),
        ])
    }

    public func updateParagraphText(_ id: UUID, text: String, hash: String, at date: Date) async throws {
        try await db.prepare()
        try await db.execute("UPDATE paragraph SET text = ?, text_hash = ?, updated_at = ? WHERE id = ?", [.string(text), .string(hash), .double(date.timeIntervalSince1970), .string(id.uuidString)])
    }

    public func insertTake(_ take: Take) async throws {
        try await db.prepare()
        let rows = try await db.query("SELECT project_id FROM paragraph WHERE id = ?", [.string(take.paragraphID.uuidString)])
        let projectID = rows.first?.string("project_id").flatMap(UUID.init(uuidString:)) ?? take.paragraphID
        try await saveTake(db, take, paragraphID: take.paragraphID, projectID: projectID)
    }

    public func setSelectedTake(_ takeID: UUID?, forParagraph pid: UUID) async throws {
        try await db.prepare()
        try await db.execute("UPDATE paragraph SET selected_take_id = ? WHERE id = ?", [takeID.map { .string($0.uuidString) } ?? .null, .string(pid.uuidString)])
    }

    public func setTakeMetrics(_ metrics: AudioQualityMetrics, forTake tid: UUID) async throws {
        try await db.prepare()
        let j = try encoder.encode(metrics)
        try await db.execute("UPDATE take SET metrics_json = ? WHERE id = ?", [.string(String(data: j, encoding: .utf8)!), .string(tid.uuidString)])
    }

    public func archiveTake(_ id: UUID, archived: Bool) async throws {
        try await db.prepare()
        try await db.execute("UPDATE take SET is_archived = ? WHERE id = ?", [.bool(archived), .string(id.uuidString)])
    }

    public func appendEvents(_ events: [ReviewEvent]) async throws {
        try await db.prepare()
        for evt in events {
            try await db.execute("INSERT OR IGNORE INTO review_event (id,project_id,paragraph_id,type,note_text,tag,device,created_at,applied_at,origin) VALUES (?,?,?,?,?,?,?,?,?,?)", [
                .string(evt.id.uuidString), .string(evt.projectID.uuidString), .string(evt.paragraphID.uuidString), .string(evt.type.rawValue),
                evt.noteText.map{.string($0)} ?? .null, evt.tag.map{.string($0.rawValue)} ?? .null, .string(evt.device.rawValue),
                .double(evt.createdAt.timeIntervalSince1970), evt.appliedAt.map{.double($0.timeIntervalSince1970)} ?? .null, .string(evt.origin.rawValue)
            ])
        }
    }

    public func unappliedEvents() async throws -> [ReviewEvent] {
        try await db.prepare()
        let rows = try await db.query("SELECT * FROM review_event WHERE applied_at IS NULL ORDER BY created_at")
        return rows.compactMap { try? loadEvent(from: $0) }
    }

    public func markEventsApplied(_ ids: [UUID], at date: Date) async throws {
        try await db.prepare()
        for id in ids {
            try await db.execute("UPDATE review_event SET applied_at = ? WHERE id = ?", [.double(date.timeIntervalSince1970), .string(id.uuidString)])
        }
    }

    public func setReviewState(_ state: ReviewState, forParagraph id: UUID) async throws {
        try await db.prepare()
        try await db.execute("UPDATE paragraph SET review_state = ?, updated_at = ? WHERE id = ?", [.string(state.rawValue), .double(clock.now.timeIntervalSince1970), .string(id.uuidString)])
    }

    public func insertNote(_ note: ReviewNote) async throws {
        try await db.prepare()
        let projID = try await db.query("SELECT project_id FROM paragraph WHERE id = ?", [.string(note.paragraphID.uuidString)]).first?.string("project_id") ?? ""
        try await db.execute("INSERT INTO review_note (id,project_id,paragraph_id,text,tag,device,timecode,created_at,resolved_at) VALUES (?,?,?,?,?,?,?,?,?)", [
            .string(note.id.uuidString), .string(projID), .string(note.paragraphID.uuidString), .string(note.text),
            note.tag.map{.string($0.rawValue)} ?? .null, .string(note.device.rawValue),
            note.timecode.map{.double($0)} ?? .null, .double(note.createdAt.timeIntervalSince1970),
            note.resolvedAt.map{.double($0.timeIntervalSince1970)} ?? .null
        ])
    }

    public func notes(forParagraph pid: UUID) async throws -> [ReviewNote] {
        try await db.prepare()
        let rows = try await db.query("SELECT * FROM review_note WHERE paragraph_id = ? ORDER BY created_at DESC", [.string(pid.uuidString)])
        return rows.compactMap { try? loadNote(from: $0) }
    }

    public func paragraphSummaries(chapterID: UUID?) async throws -> [ParagraphSummary] {
        try await db.prepare()
        // One pass over each table, joined — no per-row correlated subqueries.
        let sql = """
        SELECT p.id, p.chapter_id, p.ordinal, p.review_state, p.role, p.is_scene_break, p.global_ordinal,
            substr(p.text, 1, 90) AS snippet,
            p.selected_take_id IS NOT NULL AS has_take,
            COALESCE(tc.take_count, 0) AS take_count,
            (SELECT t.duration FROM take t WHERE t.id = p.selected_take_id) AS duration,
            n.text AS latest_note, n.tag AS latest_tag
        FROM paragraph p
        LEFT JOIN (
            SELECT paragraph_id, COUNT(*) AS take_count
            FROM take WHERE is_archived = 0
            GROUP BY paragraph_id
        ) tc ON tc.paragraph_id = p.id
        LEFT JOIN (
            SELECT paragraph_id, text, tag, ROW_NUMBER() OVER (
                PARTITION BY paragraph_id ORDER BY created_at DESC, id DESC
            ) AS rn
            FROM review_note
        ) n ON n.paragraph_id = p.id AND n.rn = 1
        """ + (chapterID.map { _ in " WHERE p.chapter_id=?" } ?? "") + " ORDER BY p.global_ordinal, p.ordinal"
        let rows: [DatabaseRow]
        if let cid = chapterID { rows = try await db.query(sql, [.string(cid.uuidString)]) }
        else { rows = try await db.query(sql) }
        return try rows.map(ds_summary)
    }

    public func paragraphIDs(matching predicate: ReviewPredicate, order: QueueOrder) async throws -> [UUID] {
        try await db.prepare()
        var conditions: [String] = []
        var bindings: [DatabaseValue] = []

        switch predicate {
        case .allRecorded:
            conditions.append("p.selected_take_id IS NOT NULL")
        case .flagged:
            conditions.append("p.review_state = 'flagged'")
        case .needsPickup:
            conditions.append("p.review_state = 'needsPickup'")
        case .unapproved:
            conditions.append("p.selected_take_id IS NOT NULL AND p.review_state != 'approved'")
        case .unreviewed:
            conditions.append("p.selected_take_id IS NOT NULL AND p.review_state = 'unreviewed'")
        case .selectedParagraphs(let ids):
            conditions.append("p.id IN (\(ids.map { _ in "?" }.joined(separator: ",")))")
            bindings.append(contentsOf: ids.map { .string($0.uuidString) })
        case .chapter(let chID):
            conditions.append("p.chapter_id = ?")
            bindings.append(.string(chID.uuidString))
        case .tag:
            conditions.append("p.selected_take_id IS NOT NULL")
        }

        var orderClause: String
        switch order {
        case .documentOrder, .byChapter:
            orderClause = "ORDER BY p.global_ordinal, p.ordinal"
        case .flaggedFirst:
            orderClause = "ORDER BY CASE p.review_state WHEN 'flagged' THEN 0 WHEN 'needsPickup' THEN 1 WHEN 'unreviewed' THEN 2 ELSE 3 END, p.global_ordinal"
        case .shortestFirst:
            orderClause = "ORDER BY (SELECT t.duration FROM take t WHERE t.id = p.selected_take_id) ASC"
        }

        let whereClause = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
        let sql = "SELECT p.id FROM paragraph p" + whereClause + " " + orderClause
        let rows = try await db.query(sql, bindings)
        return try rows.map { row in
            guard let raw = row.string("id"), let id = UUID(uuidString: raw) else {
                throw StoreError.corruptRow("invalid paragraph id in queue query")
            }
            return id
        }
    }

    public func counts() async throws -> ProjectCounts {
        try await db.prepare()
        let projID = try await db.query("SELECT id FROM project LIMIT 1").first?.string("id") ?? ""
        let rows = try await db.query(
            "SELECT COUNT(*) AS p,SUM(selected_take_id IS NOT NULL) AS r,SUM(review_state='flagged') AS f,SUM(review_state='needsPickup') AS np,SUM(review_state='approved') AS a,SUM(review_state='unreviewed') AS u FROM paragraph WHERE project_id = ?",
            [.string(projID)])
        guard let r = rows.first else { return ProjectCounts() }
        let chs = try await db.query("SELECT COUNT(*) AS cnt FROM chapter WHERE project_id = ?", [.string(projID)])
        let chCount = Int(chs.first?.int("cnt") ?? 0)
        let dur = try await db.query("SELECT SUM(t.duration) AS td FROM take t JOIN paragraph p ON p.id=t.paragraph_id WHERE p.selected_take_id=t.id AND t.project_id=?", [.string(projID)])
        let td = dur.first?.double("td") ?? 0
        let ai = try await db.query("SELECT COUNT(*) AS cnt FROM take t JOIN paragraph p ON p.id=t.paragraph_id WHERE p.selected_take_id=t.id AND t.origin_kind=? AND t.project_id=?", [.string("aiImported"), .string(projID)])
        let aiCount = Int(ai.first?.int("cnt") ?? 0)
        return ProjectCounts(paragraphs: Int(r.int("p") ?? 0), recorded: Int(r.int("r") ?? 0), flagged: Int(r.int("f") ?? 0), needsPickup: Int(r.int("np") ?? 0), approved: Int(r.int("a") ?? 0), unreviewed: Int(r.int("u") ?? 0), chapters: chCount, totalRecordedDuration: td, aiOriginSelected: aiCount)
    }

    public func cachedRender(forKey key: String) async throws -> AudioAssetReference? {
        try await db.prepare()
        let rows = try await db.query("SELECT asset_sha256,asset_path,asset_bytes FROM render_cache WHERE cache_key=?", [.string(key)])
        guard let r = rows.first, let sha = r.string("asset_sha256"), let p = r.string("asset_path") else { return nil }
        let bytes = Int(r.int("asset_bytes") ?? 0)
        return AudioAssetReference(sha256: sha, relativePath: p, byteCount: bytes, contentType: "audio/x-caf")
    }

    public func storeRender(_ ref: AudioAssetReference, key: String, chapterID: UUID, duration: TimeInterval) async throws {
        try await db.prepare()
        try await db.execute("INSERT OR REPLACE INTO render_cache (cache_key,chapter_id,asset_sha256,asset_path,asset_bytes,duration,created_at) VALUES (?,?,?,?,?,?,?)", [.string(key), .string(chapterID.uuidString), .string(ref.sha256), .string(ref.relativePath), .int(Int64(ref.byteCount)), .double(duration), .double(clock.now.timeIntervalSince1970)])
    }

    public func cachedProxy(forTake tid: UUID, bitrateKbps: Int) async throws -> AudioAssetReference? {
        try await db.prepare()
        let rows = try await db.query("SELECT asset_sha256,asset_path,asset_bytes FROM proxy_cache WHERE take_id=? AND bitrate_kbps=?", [.string(tid.uuidString), .int(Int64(bitrateKbps))])
        guard let r = rows.first, let sha = r.string("asset_sha256"), let p = r.string("asset_path") else { return nil }
        let bytes = Int(r.int("asset_bytes") ?? 0)
        return AudioAssetReference(sha256: sha, relativePath: p, byteCount: bytes, contentType: "audio/mp4")
    }

    public func storeProxy(_ ref: AudioAssetReference, forTake tid: UUID, bitrateKbps: Int) async throws {
        try await db.prepare()
        try await db.execute("INSERT OR REPLACE INTO proxy_cache (take_id,asset_sha256,asset_path,asset_bytes,bitrate_kbps,created_at) VALUES (?,?,?,?,?,?)", [.string(tid.uuidString), .string(ref.sha256), .string(ref.relativePath), .int(Int64(ref.byteCount)), .int(Int64(bitrateKbps)), .double(clock.now.timeIntervalSince1970)])
    }

    public func syncValue(_ key: String) async throws -> String? {
        try await db.prepare()
        return try await db.query("SELECT value FROM sync_state WHERE key=?", [.string(key)]).first?.string("value")
    }

    public func setSyncValue(_ key: String, _ value: String?) async throws {
        try await db.prepare()
        if let v = value { try await db.execute("INSERT OR REPLACE INTO sync_state (key,value) VALUES (?,?)", [.string(key), .string(v)]) }
        else { try await db.execute("DELETE FROM sync_state WHERE key=?", [.string(key)]) }
    }

    // MARK: - Internal save helpers (synchronous, called from within transaction)

    private func saveProject(_ db: ProjectDatabase, _ p: AudiobookProject) async throws {
        let recJ = try String(data: encoder.encode(p.profile.recording), encoding: .utf8)!
        let asmJ = try String(data: encoder.encode(p.profile.assembly), encoding: .utf8)!
        let subjJ = try String(data: encoder.encode(p.metadata.subjects), encoding: .utf8)!
        let srcJ = p.source.map { _ in try? String(data: encoder.encode(p.source!), encoding: .utf8)! } ?? nil
        let coverHex = p.metadata.coverRef.map { $0.sha256 } ?? nil
        let srcURL = p.rights.sourceURL?.absoluteString
        let licURL = p.rights.licenseURL?.absoluteString

        let bindings: [DatabaseValue] = [
            .string(p.id.uuidString), .string(p.metadata.title),
            p.metadata.subtitle.map{.string($0)} ?? .null, .string(p.metadata.author),
            p.metadata.translator.map{.string($0)} ?? .null, .string(p.metadata.narrator),
            .string(p.metadata.language), .string(p.metadata.description), .string(subjJ),
            p.metadata.seriesName.map{.string($0)} ?? .null,
            p.metadata.seriesIndex.map{.int(Int64($0))} ?? .null,
            p.metadata.publisher.map{.string($0)} ?? .null,
            p.metadata.copyrightYear.map{.int(Int64($0))} ?? .null,
            p.metadata.productionYear.map{.int(Int64($0))} ?? .null,
            p.metadata.rightsHolder.map{.string($0)} ?? .null,
            p.metadata.isbn.map{.string($0)} ?? .null,
            p.metadata.asin.map{.string($0)} ?? .null,
            .bool(p.metadata.isAbridged),
            coverHex.map{.string($0)} ?? .null,
            p.metadata.archiveIdentifier.map{.string($0)} ?? .null,
            .string(p.profile.purpose.rawValue), .string(p.profile.intendedDestination.rawValue),
            .string(p.rights.basis.rawValue),
            srcURL.map{.string($0)} ?? .null,
            p.rights.editionYear.map{.int(Int64($0))} ?? .null,
            .string(p.rights.evidenceNotes),
            p.rights.attestedAt.map{.double($0.timeIntervalSince1970)} ?? .null,
            p.rights.attestedBy.map{.string($0)} ?? .null,
            licURL.map{.string($0)} ?? .null,
            .string(recJ), .string(asmJ),
            .bool(p.profile.isHiddenFromDevices), .bool(p.profile.autoSyncAcceptedTakes),
            .bool(p.profile.includeSourceTextInProjection), .int(Int64(p.profile.proxyBitrateKbps)),
            srcJ.map{.string($0)} ?? .null,
            .double(p.createdAt.timeIntervalSince1970), .double(p.modifiedAt.timeIntervalSince1970),
            .int(1), .int(0)
        ]

        try await db.execute("""
            INSERT INTO project (id,title,subtitle,author,translator,narrator,language,description,subjects_json,series_name,series_index,publisher,copyright_year,production_year,rights_holder,isbn,asin,is_abridged,cover_sha256,archive_identifier,purpose,intended_destination,rights_basis,rights_source_url,rights_edition_year,rights_notes,rights_attested_at,rights_attested_by,rights_license_url,recording_json,assembly_json,hidden_from_devices,auto_sync_takes,include_source_text,proxy_bitrate_kbps,source_json,created_at,modified_at,schema_version,projection_revision)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, bindings)
    }

    private func saveChapter(_ db: ProjectDatabase, _ ch: ProductionChapter, projectID: UUID) async throws {
        try await db.execute("INSERT INTO chapter (id,project_id,ordinal,title,role,head_silence,tail_silence,notes) VALUES (?,?,?,?,?,?,?,?)", [
            .string(ch.id.uuidString), .string(projectID.uuidString), .int(Int64(ch.ordinal)), .string(ch.title),
            .string(ch.role.rawValue), ch.headSilenceOverride.map{.double($0)} ?? .null,
            ch.tailSilenceOverride.map{.double($0)} ?? .null, ch.notes.map{.string($0)} ?? .null
        ])
    }

    private func saveParagraph(_ db: ProjectDatabase, _ p: Paragraph, chapterID: UUID, projectID: UUID) async throws {
        let sfh: DatabaseValue = (p.sourceRange?.sourceFileHash).flatMap { $0.isEmpty ? nil : DatabaseValue.string($0) } ?? .null
        let sourceStart: DatabaseValue = p.sourceRange.map{.int(Int64($0.startOffset))} ?? .null
        let sourceEnd: DatabaseValue = p.sourceRange.map{.int(Int64($0.endOffset))} ?? .null
        try await db.execute("INSERT INTO paragraph (id,chapter_id,project_id,ordinal,text,text_hash,role,direction_note,selected_take_id,review_state,source_start,source_end,source_file_hash,is_scene_break,updated_at,global_ordinal) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .string(p.id.uuidString), .string(chapterID.uuidString), .string(projectID.uuidString), .int(Int64(p.ordinal)),
            .string(p.text), .string(p.textHash), .string(p.role.rawValue),
            p.directionNote.map{.string($0)} ?? .null,
            p.selectedTakeID.map{.string($0.uuidString)} ?? .null, .string(p.reviewState.rawValue),
            sourceStart, sourceEnd, sfh,
            .bool(p.isSceneBreak), .double(p.updatedAt.timeIntervalSince1970), .int(0)
        ])
    }

    private func saveTake(_ db: ProjectDatabase, _ t: Take, paragraphID: UUID, projectID: UUID) async throws {
        let procJ = try String(data: encoder.encode(t.processing), encoding: .utf8)!
        let metJ = t.metrics.map { _ in try? String(data: encoder.encode(t.metrics!), encoding: .utf8)! } ?? nil
        try await db.execute("INSERT INTO take (id,paragraph_id,project_id,asset_sha256,asset_path,asset_bytes,asset_content_type,origin_kind,origin_payload,recorded_at,duration,sample_rate,channels,bit_depth,codec,processing_json,metrics_json,label,text_hash_at_recording,is_archived) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [
            .string(t.id.uuidString), .string(paragraphID.uuidString), .string(projectID.uuidString),
            .string(t.assetRef.sha256), .string(t.assetRef.relativePath), .int(Int64(t.assetRef.byteCount)),
            .string(t.assetRef.contentType), .string(t.origin.storageKind),
            t.origin.storagePayload.map{.string($0)} ?? .null,
            .double(t.recordedAt.timeIntervalSince1970), .double(t.duration),
            .double(t.format.sampleRate), .int(Int64(t.format.channels)),
            t.format.bitDepth.map{.int(Int64($0))} ?? .null, .string(t.format.codec),
            .string(procJ), metJ.map{.string($0)} ?? .null,
            t.label.map{.string($0)} ?? .null, .string(t.textHashAtRecording), .bool(t.isArchived)
        ])
    }

    // MARK: - Internal load helpers

    private func loadProject(from row: DatabaseRow) async throws -> AudiobookProject {
        let id = try uuid(from: row, column: "id")
        let recDef: RecordingDefaults? = decodeJSON(from: row, column: "recording_json")
        let asmDef: AssemblySettings? = decodeJSON(from: row, column: "assembly_json")
        let srcDoc: SourceDocument? = decodeJSON(from: row, column: "source_json")
        let subjs: [String] = decodeJSON(from: row, column: "subjects_json") ?? []
        let coverRef: AudioAssetReference? = row.string("cover_sha256").map { AudioAssetReference(sha256: $0, relativePath: "", byteCount: 0, contentType: "image/jpeg") }

        let meta = BookMetadata(
            title: row.string("title") ?? "", subtitle: row.string("subtitle"),
            author: row.string("author") ?? "", translator: row.string("translator"),
            narrator: row.string("narrator") ?? "", language: row.string("language") ?? "en-US",
            description: row.string("description") ?? "", subjects: subjs,
            seriesName: row.string("series_name"), seriesIndex: row.int("series_index").map(Int.init),
            publisher: row.string("publisher"), copyrightYear: row.int("copyright_year").map(Int.init),
            productionYear: row.int("production_year").map(Int.init), rightsHolder: row.string("rights_holder"),
            isbn: row.string("isbn"), asin: row.string("asin"),
            isAbridged: row.bool("is_abridged") ?? false, coverRef: coverRef,
            archiveIdentifier: row.string("archive_identifier")
        )

        let rights = RightsEvidence(
            basis: RightsBasis(rawValue: row.string("rights_basis") ?? "publicDomainUS") ?? .publicDomainUS,
            sourceURL: row.string("rights_source_url").flatMap(URL.init(string:)),
            editionYear: row.int("rights_edition_year").map(Int.init),
            evidenceNotes: row.string("rights_notes") ?? "",
            attestedAt: row.double("rights_attested_at").map { Date(timeIntervalSince1970: $0) },
            attestedBy: row.string("rights_attested_by"),
            licenseURL: row.string("rights_license_url").flatMap(URL.init(string:))
        )

        let profile = ProductionProfile(
            purpose: ProjectPurpose(rawValue: row.string("purpose") ?? "publicDomainCommunity") ?? .publicDomainCommunity,
            recording: recDef ?? RecordingDefaults(),
            assembly: asmDef ?? AssemblySettings(),
            intendedDestination: DestinationID(rawValue: row.string("intended_destination") ?? "librivox") ?? .librivox,
            isHiddenFromDevices: row.bool("hidden_from_devices") ?? false,
            autoSyncAcceptedTakes: row.bool("auto_sync_takes") ?? true,
            includeSourceTextInProjection: row.bool("include_source_text") ?? true,
            proxyBitrateKbps: Int(row.int("proxy_bitrate_kbps") ?? 80)
        )

        return AudiobookProject(id: id, metadata: meta, rights: rights, profile: profile, source: srcDoc, chapters: [],
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            modifiedAt: Date(timeIntervalSince1970: row.double("modified_at") ?? 0),
            schemaVersion: Int(row.int("schema_version") ?? 1))
    }

    private func loadChapter(from row: DatabaseRow) async throws -> ProductionChapter {
        ProductionChapter(id: try uuid(from: row, column: "id"),
            ordinal: Int(row.int("ordinal") ?? 0), title: row.string("title") ?? "",
            role: ChapterRole(rawValue: row.string("role") ?? "body") ?? .body, paragraphs: [],
            headSilenceOverride: row.double("head_silence"), tailSilenceOverride: row.double("tail_silence"),
            notes: row.string("notes"))
    }

    private func loadParagraph(from row: DatabaseRow) throws -> Paragraph {
        var sr: SourceRange? = nil
        if let so = row.int("source_start"), let se = row.int("source_end") {
            sr = SourceRange(startOffset: Int(so), endOffset: Int(se), sourceFileHash: row.string("source_file_hash") ?? "")
        }
        return Paragraph(id: try uuid(from: row, column: "id"), ordinal: Int(row.int("ordinal") ?? 0),
            text: row.string("text") ?? "", textHash: row.string("text_hash") ?? "",
            role: ParagraphRole(rawValue: row.string("role") ?? "body") ?? .body,
            directionNote: row.string("direction_note"), pronunciationRefs: [], takes: [],
            selectedTakeID: row.string("selected_take_id").flatMap(UUID.init(uuidString:)),
            reviewState: ReviewState(rawValue: row.string("review_state") ?? "unreviewed") ?? .unreviewed,
            sourceRange: sr, isSceneBreak: row.bool("is_scene_break") ?? false,
            updatedAt: Date(timeIntervalSince1970: row.double("updated_at") ?? 0))
    }

    private func loadTake(from row: DatabaseRow) async throws -> Take {
        let kind = row.string("origin_kind") ?? "unknownImport"
        let payload = row.string("origin_payload")
        let origin: AudioOrigin = switch kind {
        case "recorded": .recorded
        case "importedHuman": .importedHuman(sourceFilename: payload ?? "")
        case "aiImported": .aiImported(providerLabel: payload ?? "")
        default: .unknownImport(sourceFilename: payload ?? "")
        }
        let proc: [AudioProcessingStep] = decodeJSON(from: row, column: "processing_json") ?? []
        let met: AudioQualityMetrics? = decodeJSON(from: row, column: "metrics_json")
        return Take(id: try uuid(from: row, column: "id"), paragraphID: try uuid(from: row, column: "paragraph_id"),
            assetRef: AudioAssetReference(sha256: row.string("asset_sha256") ?? "", relativePath: row.string("asset_path") ?? "", byteCount: Int(row.int("asset_bytes") ?? 0), contentType: row.string("asset_content_type") ?? "audio/wav"),
            origin: origin, recordedAt: Date(timeIntervalSince1970: row.double("recorded_at") ?? 0),
            duration: row.double("duration") ?? 0,
            format: AudioFormatDescription(sampleRate: row.double("sample_rate") ?? 44100, channels: Int(row.int("channels") ?? 1), bitDepth: row.int("bit_depth").map(Int.init), codec: row.string("codec") ?? "pcm"),
            processing: proc, metrics: met, label: row.string("label"),
            textHashAtRecording: row.string("text_hash_at_recording") ?? "", isArchived: row.bool("is_archived") ?? false)
    }

    private func loadEvent(from row: DatabaseRow) throws -> ReviewEvent? {
        guard let type = ReviewEventType(rawValue: row.string("type") ?? "") else { return nil }
        return ReviewEvent(id: try uuid(from: row, column: "id"),
            projectID: try uuid(from: row, column: "project_id"),
            paragraphID: try uuid(from: row, column: "paragraph_id"), type: type,
            noteText: row.string("note_text"), tag: row.string("tag").flatMap(ReviewTag.init(rawValue:)),
            device: DeviceKind(rawValue: row.string("device") ?? "mac") ?? .mac,
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            appliedAt: row.double("applied_at").map { Date(timeIntervalSince1970: $0) },
            origin: ReviewEvent.Origin(rawValue: row.string("origin") ?? "local") ?? .local)
    }

    private func loadNote(from row: DatabaseRow) throws -> ReviewNote {
        ReviewNote(id: try uuid(from: row, column: "id"), paragraphID: try uuid(from: row, column: "paragraph_id"),
            text: row.string("text") ?? "", tag: row.string("tag").flatMap(ReviewTag.init(rawValue:)),
            device: DeviceKind(rawValue: row.string("device") ?? "mac") ?? .mac,
            timecode: row.double("timecode"), createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            resolvedAt: row.double("resolved_at").map { Date(timeIntervalSince1970: $0) })
    }

    private func ds_summary(from row: DatabaseRow) throws -> ParagraphSummary {
        ParagraphSummary(id: try uuid(from: row, column: "id"),
            chapterID: try uuid(from: row, column: "chapter_id"),
            ordinal: Int(row.int("ordinal") ?? 0), globalOrdinal: Int(row.int("global_ordinal") ?? 0),
            snippet: row.string("snippet") ?? "",
            reviewState: ReviewState(rawValue: row.string("review_state") ?? "unreviewed") ?? .unreviewed,
            hasSelectedTake: row.bool("has_take") ?? false, takeCount: Int(row.int("take_count") ?? 0),
            duration: row.double("duration"),
            latestNoteSnippet: row.string("latest_note"),
            latestNoteTag: row.string("latest_tag").flatMap(ReviewTag.init(rawValue:)),
            role: ParagraphRole(rawValue: row.string("role") ?? "body") ?? .body)
    }

    private func decodeJSON<T: Decodable>(from row: DatabaseRow, column: String) -> T? {
        guard let s = row.string(column), !s.isEmpty, let d = s.data(using: .utf8) else { return nil }
        return try? decoder.decode(T.self, from: d)
    }

    private func uuid(from row: DatabaseRow, column: String) throws -> UUID {
        guard let raw = row.string(column), let id = UUID(uuidString: raw) else {
            throw StoreError.corruptRow("invalid UUID in column \(column)")
        }
        return id
    }
}
