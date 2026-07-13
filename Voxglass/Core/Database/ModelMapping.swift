import Foundation

enum ModelMapping {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    static func databaseValue(_ uuid: UUID) -> DatabaseValue {
        .string(uuid.uuidString)
    }

    static func databaseValue(_ url: URL?) -> DatabaseValue {
        guard let url else { return .null }
        return .string(url.absoluteString)
    }

    static func databaseValue(_ value: String?) -> DatabaseValue {
        guard let value else { return .null }
        return .string(value)
    }

    static func databaseValue(_ date: Date) -> DatabaseValue {
        .double(date.timeIntervalSince1970)
    }

    static func databaseValue(_ value: TimeInterval?) -> DatabaseValue {
        guard let value else { return .null }
        return .double(value)
    }

    static func databaseValue(_ value: Int?) -> DatabaseValue {
        guard let value else { return .null }
        return .int(Int64(value))
    }

    static func databaseValue(_ value: Int64?) -> DatabaseValue {
        guard let value else { return .null }
        return .int(value)
    }

    static func uuid(_ row: DatabaseRow, _ column: String) throws -> UUID {
        let value = try row.requiredString(column)
        guard let uuid = UUID(uuidString: value) else {
            throw DatabaseError.invalidUUID(value)
        }
        return uuid
    }

    static func date(_ row: DatabaseRow, _ column: String) -> Date {
        Date(timeIntervalSince1970: row.double(column) ?? 0)
    }

    static func url(_ row: DatabaseRow, _ column: String) -> URL? {
        row.string(column).flatMap(URL.init(string:))
    }

    static func authors(from row: DatabaseRow) -> [String] {
        guard
            let json = row.string("authors_json"),
            let data = json.data(using: .utf8),
            let authors = try? decoder.decode([String].self, from: data)
        else {
            return []
        }
        return authors
    }

    static func narrators(from row: DatabaseRow) -> [String] {
        guard
            let json = row.string("narrators_json"),
            let data = json.data(using: .utf8),
            let narrators = try? decoder.decode([String].self, from: data)
        else {
            return []
        }
        return narrators
    }

    static func authorsJSON(_ authors: [String]) -> String {
        guard
            let data = try? encoder.encode(authors),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    static func narratorsJSON(_ narrators: [String]) -> String {
        guard
            let data = try? encoder.encode(narrators),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }
}

