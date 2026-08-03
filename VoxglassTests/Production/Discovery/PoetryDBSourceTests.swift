import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

@Suite struct PoetryDBSourceTests {

    let source = PoetryDBNeedsSource()

    @Test func decodesPoemsAndCapsLineCount() throws {
        let json = """
        [
          { "title": "Fire and Ice", "author": "Robert Frost", "lines": ["Some say the world will end in fire,", "Some say in ice."], "linecount": "2" },
          { "title": "The Raven", "author": "Edgar Allan Poe", "lines": ["Once upon a midnight dreary..."], "linecount": "108" }
        ]
        """
        let needs = try source.decode(Data(json.utf8), clock: FixedClock())
        // The 108-line poem exceeds the 40-line ceiling → dropped.
        #expect(needs.count == 1)
        let need = needs.first!
        #expect(need.work.title == "Fire and Ice")
        #expect(need.work.grade == .practice) // no citable per-poem edition
        #expect(!need.isSubmittable)
        #expect(need.work.estSeconds == 6)
        #expect(need.work.text?.contains("end in fire") == true)
    }

    @Test func errorObjectThrows() {
        let json = #"{ "status": 404, "reason": "Not found" }"#
        #expect(throws: (any Error).self) {
            try source.decode(Data(json.utf8), clock: FixedClock())
        }
    }

    @Test func emptyArrayYieldsNothing() throws {
        let needs = try source.decode(Data("[]".utf8), clock: FixedClock())
        #expect(needs.isEmpty)
    }
}
