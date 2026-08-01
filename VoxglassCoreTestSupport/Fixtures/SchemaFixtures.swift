import Foundation

/// Access to captured DDL snapshots (§7.4 rule 4: migration tests must build
/// the *old* schema from a captured snapshot, not from the current migration
/// list, so later migrations are tested against the schema real installs had).
public enum SchemaFixtures {
    /// The captured v1 schema (initial_production_schema).
    public static func v1SQL() throws -> String {
        guard let url = Bundle.module.url(forResource: "v1", withExtension: "sql", subdirectory: "Schemas") else {
            throw SchemaFixtureError.missing("Schemas/v1.sql")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

public enum SchemaFixtureError: Error {
    case missing(String)
}
