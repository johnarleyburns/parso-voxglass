import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// Spec §19.8: drives a 5-second fake recording and asserts the teleprompter's
/// render count stays below 3 while the meter's invalidation count exceeds 100 —
/// proving the §11.3 isolation works rather than merely that nothing crashed.
///
/// The meter side is asserted at the observation layer (`withObservationTracking`):
/// @Observable invalidation notifications are exactly the signal that schedules
/// SwiftUI re-renders, and counting them is deterministic in a headless test
/// host where live window-server display cycles are not. The teleprompter guard
/// stays at the view layer (`RenderCounter`), which is reliable in both.
@MainActor
@Suite struct RenderCountProbeTests {

    @Test func teleprompterDoesNotInvalidateWhileMeterUpdates() async throws {
        #if DEBUG
        let capture = FakeAudioCapture()
        capture.takeDuration = 10
        capture.levelRate = 0.033
        let store = InMemoryProductionStore()
        let assets = InMemoryAssetStore()
        let paragraph = Paragraph(id: UUID(), ordinal: 0, text: "The teleprompter text that must not re-render while the meter updates at thirty hertz for the full duration of this probe.", textHash: "h")
        let project = AudiobookProject(id: UUID(), metadata: BookMetadata(title: "T", author: "A", narrator: "N"), chapters: [ProductionChapter(id: UUID(), ordinal: 0, title: "C", paragraphs: [paragraph])])
        try await store.save(project)
        let model = RecordingModel(capture: capture, store: store, assets: assets, projectID: project.id)
        await model.loadProject()
        await model.prepare()

        // Observation-layer count of meter invalidations during the recording:
        // @Observable invalidations are the signal that schedules SwiftUI
        // re-renders, and counting them is deterministic in a headless host.
        let meter = model.meter
        final class Counter: @unchecked Sendable {
            nonisolated(unsafe) var value = 0
        }
        let invalidations = Counter()
        func armMeterTracking() {
            _ = withObservationTracking {
                _ = meter.peakDBFS
                _ = meter.elapsed
            } onChange: {
                invalidations.value += 1
                MainActor.assumeIsolated { armMeterTracking() }
            }
        }
        armMeterTracking()

        RenderCounter.counts.removeAll()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: RecordingWorkspaceView(
            model: model,
            paragraph: paragraph,
            paragraphIndex: 0,
            totalParagraphs: 1
        ))
        window.makeKeyAndOrderFront(nil)

        await model.startRecording(paragraphID: paragraph.id)
        RenderCounter.counts.removeAll()

        // Pump the runloop for ~4.5 s of fake recording. The meter receives a
        // level update every 33 ms; each must invalidate.
        let deadline = Date().addingTimeInterval(4.5)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try await Task.yield()
        }

        let teleprompter = RenderCounter.counts["record.teleprompter", default: 0]
        await model.stopRecording()
        window.orderOut(nil)

        #expect(invalidations.value > 100, "meter only invalidated \(invalidations.value) times at ~30 Hz over 4.5 s")
        #expect(teleprompter < 3, "teleprompter rendered \(teleprompter) times during recording")
        #endif
    }
}
