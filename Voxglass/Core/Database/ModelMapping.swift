import Foundation

public enum ModelMapping {
    public static let encoder = JSONEncoder()
    public static let decoder = JSONDecoder()

    public static func databaseValue(_ uuid: UUID) -> DatabaseValue {
        .string(uuid.uuidString)
    }

    public static func databaseValue(_ url: URL?) -> DatabaseValue {
        guard let url else { return .null }
        return .string(url.absoluteString)
    }

    public static func databaseValue(_ value: String?) -> DatabaseValue {
        guard let value else { return .null }
        return .string(value)
    }

    public static func databaseValue(_ date: Date) -> DatabaseValue {
        .double(date.timeIntervalSince1970)
    }

    public static func databaseValue(_ value: TimeInterval?) -> DatabaseValue {
        guard let value else { return .null }
        return .double(value)
    }

    public static func databaseValue(_ value: Int?) -> DatabaseValue {
        guard let value else { return .null }
        return .int(Int64(value))
    }

    public static func databaseValue(_ value: Int64?) -> DatabaseValue {
        guard let value else { return .null }
        return .int(value)
    }

    public static func uuid(_ row: DatabaseRow, _ column: String) throws -> UUID {
        let value = try row.requiredString(column)
        guard let uuid = UUID(uuidString: value) else {
            throw DatabaseError.invalidUUID(value)
        }
        return uuid
    }

    public static func date(_ row: DatabaseRow, _ column: String) -> Date {
        Date(timeIntervalSince1970: row.double(column) ?? 0)
    }

    public static func url(_ row: DatabaseRow, _ column: String) -> URL? {
        row.string(column).flatMap(URL.init(string:))
    }

    public static func authors(from row: DatabaseRow) -> [String] {
        guard
            let json = row.string("authors_json"),
            let data = json.data(using: .utf8),
            let authors = try? decoder.decode([String].self, from: data)
        else {
            return []
        }
        return authors
    }

    public static func narrators(from row: DatabaseRow) -> [String] {
        guard
            let json = row.string("narrators_json"),
            let data = json.data(using: .utf8),
            let narrators = try? decoder.decode([String].self, from: data)
        else {
            return []
        }
        return narrators
    }

    public static func authorsJSON(_ authors: [String]) -> String {
        guard
            let data = try? encoder.encode(authors),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    public static func narratorsJSON(_ narrators: [String]) -> String {
        guard
            let data = try? encoder.encode(narrators),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }
}

