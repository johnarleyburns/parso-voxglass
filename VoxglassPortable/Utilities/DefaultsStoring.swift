import Foundation

/// Generic `UserDefaults`-shaped storage seam.
///
/// Production types accept this instead of a concrete `UserDefaults` so tests
/// can pass `InMemoryDefaultsStore` and avoid the preferences daemon, plist
/// files, and their synchronous IPC. `UserDefaults` itself conforms, so no
/// production call site needs to change.
public protocol DefaultsStoring: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func bool(forKey defaultName: String) -> Bool
    func data(forKey defaultName: String) -> Data?
    func integer(forKey defaultName: String) -> Int
    func float(forKey defaultName: String) -> Float
    func double(forKey defaultName: String) -> Double
    func string(forKey defaultName: String) -> String?
    func stringArray(forKey defaultName: String) -> [String]?
    func array(forKey defaultName: String) -> [Any]?
    func dictionary(forKey defaultName: String) -> [String: Any]?
    func dictionaryRepresentation() -> [String: Any]
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

/// A `DefaultsStoring` implementation that is safe to carry inside a
/// `Sendable` value. `UserDefaults` itself is not `Sendable`, so production
/// types that need both (for example the Watch narration cache) keep the suite
/// name for the real backend and accept this seam only in tests.
public protocol SendableDefaultsStoring: DefaultsStoring, Sendable {}

extension UserDefaults: DefaultsStoring {}

/// Process-local replacement for `UserDefaults` in tests. Every accessor is a
/// plain dictionary read/write: no preferences daemon, no file IO, and no
/// blocking work while Swift Testing runs suites concurrently.
///
/// Coercions mirror the `UserDefaults` accessors that production code relies on
/// (for example `bool`/`integer` reading an `Int`, and `stringArray` reading a
/// stored `[String]`), so a fixture written with one accessor reads back the
/// same way it would from a real domain.
public final class InMemoryDefaultsStore: SendableDefaultsStoring, @unchecked Sendable {
    private var values: [String: Any] = [:]

    public init() {}

    public func object(forKey defaultName: String) -> Any? { values[defaultName] }

    public func bool(forKey defaultName: String) -> Bool {
        switch values[defaultName] {
        case let value as Bool: return value
        case let value as Int: return value != 0
        case let value as Double: return value != 0
        case let value as String:
            return ["1", "true", "yes"].contains(value.lowercased())
        case let value as NSNumber: return value.boolValue
        default: return false
        }
    }

    public func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }

    public func integer(forKey defaultName: String) -> Int {
        switch values[defaultName] {
        case let value as Int: return value
        case let value as Bool: return value ? 1 : 0
        case let value as Double: return Int(value)
        case let value as String: return Int(value) ?? 0
        case let value as NSNumber: return value.intValue
        default: return 0
        }
    }

    public func float(forKey defaultName: String) -> Float {
        switch values[defaultName] {
        case let value as Float: return value
        case let value as Double: return Float(value)
        case let value as Int: return Float(value)
        case let value as Bool: return value ? 1 : 0
        case let value as String: return Float(value) ?? 0
        case let value as NSNumber: return value.floatValue
        default: return 0
        }
    }

    public func double(forKey defaultName: String) -> Double {
        switch values[defaultName] {
        case let value as Double: return value
        case let value as Float: return Double(value)
        case let value as Int: return Double(value)
        case let value as Bool: return value ? 1 : 0
        case let value as String: return Double(value) ?? 0
        case let value as NSNumber: return value.doubleValue
        default: return 0
        }
    }

    public func string(forKey defaultName: String) -> String? { values[defaultName] as? String }

    public func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }

    public func array(forKey defaultName: String) -> [Any]? { values[defaultName] as? [Any] }

    public func dictionary(forKey defaultName: String) -> [String: Any]? {
        values[defaultName] as? [String: Any]
    }

    public func dictionaryRepresentation() -> [String: Any] { values }

    public func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }

    public func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
}
