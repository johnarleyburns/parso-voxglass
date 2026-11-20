import Foundation
import Testing
@testable import VoxglassPortable

/// Proves the `DefaultsStoring` test double behaves like a `UserDefaults`
/// domain without touching the preferences daemon, and that two stores never
/// share state.
struct InMemoryDefaultsStoreTests {

    @Test func roundTripsUserDefaultsShapedValues() {
        let defaults = InMemoryDefaultsStore()

        defaults.set(true, forKey: "bool")
        defaults.set(42, forKey: "int")
        defaults.set(Float(1.5), forKey: "float")
        defaults.set(2.5, forKey: "double")
        defaults.set("value", forKey: "string")
        defaults.set(["a", "b"], forKey: "stringArray")
        defaults.set(Data("bytes".utf8), forKey: "data")
        defaults.set(["key": "value"], forKey: "dictionary")
        defaults.set([Data("array".utf8)], forKey: "array")

        #expect(defaults.bool(forKey: "bool"))
        #expect(defaults.integer(forKey: "int") == 42)
        #expect(defaults.float(forKey: "float") == 1.5)
        #expect(defaults.double(forKey: "double") == 2.5)
        #expect(defaults.string(forKey: "string") == "value")
        #expect(defaults.stringArray(forKey: "stringArray") == ["a", "b"])
        #expect(defaults.data(forKey: "data") == Data("bytes".utf8))
        #expect((defaults.dictionary(forKey: "dictionary") as? [String: String]) == ["key": "value"])
        #expect((defaults.array(forKey: "array") as? [Data]) == [Data("array".utf8)])
        #expect(defaults.dictionaryRepresentation().count == 9)
    }

    @Test func coercionMatchesUserDefaultsAccessors() {
        let defaults = InMemoryDefaultsStore()

        defaults.set(1, forKey: "intAsBool")
        #expect(defaults.bool(forKey: "intAsBool"))

        defaults.set(true, forKey: "boolAsInt")
        #expect(defaults.integer(forKey: "boolAsInt") == 1)

        defaults.set("7", forKey: "stringAsInt")
        #expect(defaults.integer(forKey: "stringAsInt") == 7)

        defaults.set("unknown", forKey: "stringAsInt")
        #expect(defaults.integer(forKey: "stringAsInt") == 0)
        #expect(defaults.bool(forKey: "missing") == false)
        #expect(defaults.string(forKey: "missing") == nil)
    }

    @Test func storesAreIsolatedAndRemovalClearsOnlyOneKey() {
        let first = InMemoryDefaultsStore()
        let second = InMemoryDefaultsStore()

        first.set("one", forKey: "key")
        second.set("two", forKey: "key")
        first.set("keep", forKey: "other")

        #expect(first.string(forKey: "key") == "one")
        #expect(second.string(forKey: "key") == "two")

        first.removeObject(forKey: "key")
        #expect(first.string(forKey: "key") == nil)
        #expect(first.string(forKey: "other") == "keep")
        #expect(second.string(forKey: "key") == "two")

        first.set(nil, forKey: "other")
        #expect(first.string(forKey: "other") == nil)
    }
}
