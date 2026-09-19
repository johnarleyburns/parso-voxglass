import Testing
import VoxglassCore

@Suite struct CarPlayConnectionStateTests {
    @Test func validationResultExposesNormalizedStateAndFallbackDecision() {
        let result = CarPlayTemplateValidationResult(
            normalizedTabs: ["continue"],
            droppedIDs: ["duplicate"],
            diagnosticReason: "duplicateID"
        )
        #expect(result.normalizedTabs == ["continue"])
        #expect(result.droppedIDs == ["duplicate"])
        #expect(result.diagnosticReason == "duplicateID")
        #expect(!result.requiresFallback)

        let fallback = CarPlayTemplateValidationResult<String>(
            normalizedTabs: [],
            diagnosticReason: "emptyInput"
        )
        #expect(fallback.requiresFallback)
    }

    @Test func reconnectSupersedesOlderConnection() {
        var machine = CarPlayConnectionStateMachine()
        let first = machine.connect()
        let second = machine.connect()

        #expect(second > first)
        #expect(!machine.owns(first))
        #expect(machine.owns(second))
        let staleFinish = machine.finishConnect(generation: first, mode: .consumer)
        let currentFinish = machine.finishConnect(generation: second, mode: .production)
        #expect(!staleFinish)
        #expect(currentFinish)
        #expect(machine.state == .connected(generation: second, mode: .production))
    }

    @Test func disconnectInvalidatesPendingBootstrap() {
        var machine = CarPlayConnectionStateMachine()
        let generation = machine.connect()
        machine.disconnect()

        #expect(!machine.owns(generation))
        let lateFinish = machine.finishConnect(generation: generation, mode: .consumer)
        #expect(!lateFinish)
        #expect(machine.state == .disconnected)
    }
}
