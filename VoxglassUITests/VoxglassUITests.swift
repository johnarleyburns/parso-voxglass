import XCTest
import VoxglassCore

/// The single simulator smoke test for Voxglass. Everything else is covered by
/// the host `swift test` logic suite (VoxglassCore); this proves the app boots,
/// every tab renders, the EQ is reachable, My Productions is reachable (seeded
/// via `-uiTestSeed onePreviewProject`), and — the §16.3 test-1 path — a short
/// narration is created from a need, recorded end to end with the fake capture,
/// reviewed, validated, exported to LibriVox, and the **produced package is
/// verified against the real output bytes** (128 kbps CBR / 44.1 kHz / mono,
/// ID3 tags, checksums, checklist, metadata.json).
///
/// Run locally on iPhone 16 — CI runs `swift test` only and never runs this
/// target. One UI smoke test per device by repo convention.
final class VoxglassUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppBootsVisitsAllTabsEQAndProductions() {
        let app = XCUIApplication()

        // The app writes exports into this shared host path (via the
        // `-uiTestExportDirectory` hook) so the test can read and verify the
        // produced bytes itself. Inert in normal runs.
        let exportDir = "/tmp/voxglass-uitest-exports-\(UUID().uuidString.prefix(8))"
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)

        app.launchArguments += [
            "-voxglass.hasCompletedSplash", "YES",
            "-voxglass.hasCompletedOnboarding", "YES",
            "-voxglass.narration.onboardingSeen.v1", "YES",
            "-VoxglassInitialTab", "home",
            "-VoxglassDisableAnimatedSplash",
            // Starts the narration flow from a clean store so the record step
            // is deterministic (resume could land on Review/Assemble instead).
            "-uiTestResetNarrations",
            // Scripted capture: the record step must never depend on the
            // simulator's audio input (unreliable since iOS 17) — the fake
            // writes silent takes so the flow runs end-to-end with no mic.
            "-uiTestFakeCapture",
            // Seeds one previewable production (WP-G) and keeps the G-8 guard
            // honest that no UI test runs without a declared test environment.
            "-uiTestSeed", "onePreviewProject",
            // Redirect the export output to a path the test process can read.
            "-uiTestExportDirectory", exportDir,
            // On a real device MediaPlayer invokes the MPMediaItemArtwork
            // requestHandler from a background queue; a contextually @MainActor
            // handler traps there and kills the app on launch. This hook runs
            // that same off-main call on the simulator, where MediaPlayer never
            // renders Now Playing and would otherwise never exercise the path.
            "-uiTestExerciseArtworkOffMain"
        ]
        app.launch()

        // Boots into the Listen tab. The artwork requestHandler was already
        // invoked from a background queue during launch, so this proves the
        // app survived the off-main call that crashes contextually-isolated
        // handlers on device (TestFlight startup crash).
        XCTAssertTrue(
            app.staticTexts["Recommended for You"].waitForExistence(timeout: 15),
            "App did not boot into the Listen tab — artwork requestHandler may have crashed off-main.\n\(app.debugDescription)"
        )
        XCTAssertEqual(
            app.state,
            .runningForeground,
            "App terminated after the off-main artwork requestHandler call (executor isolation trap)."
        )

        // Every tab is reachable and renders a stable anchor without crashing.
        let tabs: [(button: String, anchor: String)] = [
            ("My Books", "My Books"),
            ("Explore", "Featured Collections"),
            ("Narration", "Start a Narration"),
            ("Listen", "Recommended for You")
        ]
        for tab in tabs {
            app.buttons[tab.button].tap()
            XCTAssertTrue(
                app.staticTexts[tab.anchor].waitForExistence(timeout: 10),
                "Tab \(tab.button) did not render its content"
            )
        }

        // My Productions reachability (spec §18.2, WP-G): Library → My
        // Productions → seeded project card → detail review actions.
        app.buttons["My Books"].tap()
        let shelf = app.buttons["shelf.myProductions"]
        XCTAssertTrue(
            shelf.waitForExistence(timeout: 10),
            "My Productions entry not on the Library tab.\n\(app.debugDescription)"
        )
        shelf.tap()

        let card = app.descendants(matching: .any)["production.themurderofrogerackroyd"]
        XCTAssertTrue(
            card.waitForExistence(timeout: 10),
            "Seeded production card did not render.\n\(app.debugDescription)"
        )
        card.tap()
        XCTAssertTrue(
            app.buttons["detail.playWholeBook"].waitForExistence(timeout: 10),
            "detail.playWholeBook not reachable.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.buttons["detail.reviewFlagged"].exists,
            "detail.reviewFlagged not reachable.\n\(app.debugDescription)"
        )

        // ──────────────────────────────────────────────────────────────────
        // §16.3 test 1: Narration → create a project from a need → record
        // every paragraph (at least two) with the fake capture → review →
        // validate → LibriVox export, then verify the produced files.
        // ──────────────────────────────────────────────────────────────────
        app.buttons["Narration"].tap()
        XCTAssertTrue(
            app.staticTexts["Start a Narration"].waitForExistence(timeout: 10),
            "Narration tab did not render after returning\n\(app.debugDescription)"
        )

        let startNarrationShelf = app.descendants(matching: .any)["home.startNarrationShelf"]
        XCTAssertTrue(
            startNarrationShelf.exists,
            "Start a Narration shelf not found on Narration tab.\n\(app.debugDescription)"
        )

        let featuredNeed = app.buttons["needs.featured"]
        for _ in 0..<8 where !featuredNeed.exists {
            app.swipeUp()
            _ = featuredNeed.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(
            featuredNeed.waitForExistence(timeout: 30),
            "Featured narration need not found after ladder load.\n\(app.debugDescription)"
        )
        for _ in 0..<4 where featuredNeed.exists && !featuredNeed.isHittable {
            app.swipeUp()
            _ = featuredNeed.waitForExistence(timeout: 2)
        }
        featuredNeed.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["record.teleprompter"].waitForExistence(timeout: 10),
            "Record screen did not open.\n\(app.debugDescription)"
        )

        // Record every paragraph with the fake capture. The first paragraph is
        // flagged (not accepted) so the flow lands on the Review screen — a
        // fully-accepted recording skips Review in this app — and the rest are
        // accepted. The loop ends when the record screen is replaced by Review.
        var recorded = recordParagraphs(in: app, flagFirst: true)
        XCTAssertTrue(
            recorded >= 2,
            "§16.3 requires recording at least two paragraphs; recorded \(recorded).\n\(app.debugDescription)"
        )

        // Review leg: the flagged paragraph must block assembly.
        let assembleButton = app.buttons["review.toAssemble"]
        XCTAssertTrue(
            assembleButton.waitForExistence(timeout: 10),
            "Review screen did not appear after recording.\n\(app.debugDescription)"
        )
        XCTAssertFalse(assembleButton.isEnabled, "A flagged paragraph must disable assemble (review gate).")

        // Re-record the flagged paragraph from the review list, which clears the
        // flag (a take overwrites reviewState). Re-recording advances through
        // the remaining paragraphs, so run the same record loop again.
        let rerecord = app.buttons["Re-record ▸"]
        XCTAssertTrue(rerecord.waitForExistence(timeout: 10), "Flagged row has no Re-record action.\n\(app.debugDescription)")
        rerecord.tap()
        recorded = recordParagraphs(in: app, flagFirst: false)

        // Re-recording clears the flag, so the flow is ready: either the Review
        // screen reappears with the gate open, or it routes straight to Assemble.
        if app.buttons["review.toAssemble"].waitForExistence(timeout: 5) {
            XCTAssertTrue(
                app.buttons["review.toAssemble"].isEnabled,
                "Resolving the flag must re-enable assembly.\n\(app.debugDescription)"
            )
            app.buttons["review.toAssemble"].tap()
        }
        XCTAssertTrue(
            app.buttons["assemble.continue"].waitForExistence(timeout: 10),
            "Assemble screen did not open.\n\(app.debugDescription)"
        )
        app.buttons["assemble.continue"].tap()

        // Metadata: narrator is required by `hasMetadata`. The app now restores
        // the locally saved narrator name, so preserve it when present; only
        // seed the legacy fallback for a completely fresh simulator profile.
        // This keeps the recorded disclaimers matching the validation engine's
        // script plan (staleDisclaimerText would otherwise block export).
        // Title/author come from the need and must not change.
        // The featured need carries no source edition URL, so one is entered
        // here (the metadata screen persists it via `attest()`).
        let narrator = app.textFields["metadata.narrator"]
        XCTAssertTrue(narrator.waitForExistence(timeout: 10), "Metadata screen did not open.\n\(app.debugDescription)")
        let savedNarrator = (narrator.value as? String) ?? ""
        if savedNarrator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            narrator.tap()
            narrator.typeText("your name")
        }

        app.swipeUp()
        let sourceURLField = app.textFields["metadata.sourceURL"]
        XCTAssertTrue(sourceURLField.waitForExistence(timeout: 10), "Source URL field not reachable.\n\(app.debugDescription)")
        sourceURLField.tap()
        sourceURLField.typeText("https://www.gutenberg.org/ebooks/12242")

        // Dismiss the keyboard so the attest button below is tappable.
        if app.keyboards.firstMatch.exists {
            let returnKey = app.keyboards.buttons["return"]
            if returnKey.exists {
                returnKey.tap()
            } else {
                app.swipeDown()
            }
        }

        let attest = app.buttons["metadata.attest"]
        for _ in 0..<3 where !attest.exists {
            app.swipeUp()
            _ = attest.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(attest.waitForExistence(timeout: 10))
        attest.tap()

        let toExport = app.buttons["metadata.toExport"]
        XCTAssertTrue(
            toExport.waitForExistence(timeout: 10),
            "Validate & export not reachable.\n\(app.debugDescription)"
        )
        XCTAssertTrue(toExport.isEnabled, "Rights attestation did not enable export.\n\(app.debugDescription)")
        toExport.tap()

        // Validation: the report must be clean of blocking issues for LibriVox.
        XCTAssertTrue(
            app.descendants(matching: .any)["validate.report"].waitForExistence(timeout: 15),
            "Validation report did not render.\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '0 blocking'")).firstMatch
                .waitForExistence(timeout: 15),
            "LibriVox validation has blocking issues — export is unreachable.\n\(app.debugDescription)"
        )

        // Export scope (§13.2, F1): export a single chapter — LibriVox's real
        // per-post workflow — and the package must contain exactly that one
        // section. For the short need the whole book is one chapter, but the
        // scope picker wiring is exercised for real.
        let scopeChapter = app.buttons["export.scope.chapter"]
        XCTAssertTrue(scopeChapter.waitForExistence(timeout: 10), "Scope picker not on export screen.\n\(app.debugDescription)")
        scopeChapter.tap()

        let produce = app.buttons["validation.continueToExport"]
        XCTAssertTrue(
            produce.waitForExistence(timeout: 10),
            "Export start button not found.\n\(app.debugDescription)"
        )
        XCTAssertTrue(produce.isEnabled, "Export should be enabled with a clean report.\n\(app.debugDescription)")
        produce.tap()

        // The resumable export runs in a full-screen cover and hands off to the
        // Submit screen when the package is ready.
        XCTAssertTrue(
            app.descendants(matching: .any)["export.packageReady"].waitForExistence(timeout: 240),
            "Export did not complete to a ready package.\n\(app.debugDescription)"
        )

        verifyExportedLibriVoxPackage(exportDir: exportDir, app: app)

        // The export finishes on the flow's root (SubmitView), whose Close
        // button dismisses the whole fullScreenCover. NOTE: the underlying
        // Narration tab is always visible in accessibility snapshots, so we
        // cannot use it to detect closure — tap Close (popping Back first if
        // the flow is not at its root) and then wait for the flow content to
        // be gone.
        for _ in 0..<12 {
            if app.buttons["Close"].exists {
                app.buttons["Close"].tap()
                break
            }
            if app.buttons["BackButton"].exists {
                app.buttons["BackButton"].tap()
            } else {
                break
            }
        }
        let coverGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["export.packageReady"])
        wait(for: [coverGone], timeout: 10)

        // The EQ step needs the Listen tab anyway; switch there first (also
        // forces a clean tab re-render after the cover dismissal), then Search.
        app.buttons["Listen"].tap()
        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        // Search renders its field (kept last: it puts focus in a text field).
        app.buttons["Search"].tap()
        let searchField = app.textFields["Search LibriVox audiobooks"]
        if !searchField.waitForExistence(timeout: 20) {
            app.buttons["Search"].tap()
            _ = searchField.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(
            searchField.exists,
            "Search tab did not render its search field.\n\(app.debugDescription)"
        )

        // The ten-band EQ is reachable from the "…" menu on the home view and
        // every band is draggable — folded into the smoke test so this target
        // has exactly one.
        app.buttons["Listen"].tap()
        XCTAssertTrue(app.staticTexts["Recommended for You"].waitForExistence(timeout: 10))

        let moreMenu = app.buttons["home.moreMenu"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 10), "More menu not on home view.\n\(app.debugDescription)")
        moreMenu.tap()
        app.buttons["Equalizer"].tap()

        XCTAssertTrue(
            app.staticTexts["Equalizer"].waitForExistence(timeout: 10),
            "Equalizer sheet did not open.\n\(app.debugDescription)"
        )

        for band in 0..<10 {
            let slider = app.sliders["eq.band.\(band)"]
            XCTAssertTrue(
                slider.waitForExistence(timeout: 8),
                "EQ band \(band) slider not found.\n\(app.debugDescription)"
            )
            XCTAssertTrue(
                slider.isHittable,
                "EQ band \(band) slider is not hittable.\n\(app.debugDescription)"
            )
        }

        let band9 = app.sliders["eq.band.9"]
        let start = band9.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = band9.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    // MARK: - Narration recording helper

    /// Records every paragraph the record screen presents with the fake
    /// capture: record → stop → (flag the first paragraph when `flagFirst`, else
    /// accept) → next. The *last* take can route the flow straight to
    /// Review/Assemble before the take chip renders, so after stopping we wait
    /// for either the chip or the record screen going away, whichever comes
    /// first.
    @discardableResult
    private func recordParagraphs(in app: XCUIApplication, flagFirst: Bool) -> Int {
        var recorded = 0
        while app.buttons["record.transport.record"].waitForExistence(timeout: 5) {
            let recordButton = app.buttons["record.transport.record"]
            recordButton.tap()
            XCTAssertTrue(
                app.staticTexts["● REC"].waitForExistence(timeout: 10),
                "Recording did not start — capture failed.\n\(app.debugDescription)"
            )
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'failed'")).firstMatch.exists,
                "Recording error card shown.\n\(app.debugDescription)"
            )
            recordButton.tap() // stop

            var gone = false
            var chip = false
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if !app.buttons["record.transport.record"].exists { gone = true; break }
                if app.staticTexts["record.take.1"].exists { chip = true; break }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            recorded += 1
            if gone { break } // the last take routed the flow onward
            XCTAssertTrue(chip, "Take was not saved after stopping.\n\(app.debugDescription)")

            if flagFirst && recorded == 1 {
                let flag = app.buttons["record.flagAndNext"]
                XCTAssertTrue(flag.exists, "Flag & Next not available.\n\(app.debugDescription)")
                flag.tap()
            } else {
                let accept = app.buttons["record.acceptAndNext"]
                XCTAssertTrue(
                    accept.isEnabled,
                    "Accept & Next should be enabled once a take exists.\n\(app.debugDescription)"
                )
                accept.tap()
            }
        }
        return recorded
    }

    // MARK: - Export verification

    /// Reads the package the app wrote into the shared export directory and
    /// asserts on the actual bytes (§16.5 M-9, F4): one MP3 per exported
    /// section, 128 kbps CBR / 44.1 kHz / mono via `MP3FrameParser.verifies`,
    /// ID3 tags carrying the project's title/author/album/track, a
    /// `checksums.sha256` whose digests match the files on disk, and the
    /// generated checklist + `metadata.json`.
    private func verifyExportedLibriVoxPackage(exportDir: String, app: XCUIApplication) {
        let root = URL(fileURLWithPath: exportDir)
        let packageRoot: URL
        if let lib = try? root.appendingPathComponent("LibriVox", isDirectory: true),
           let first = try? FileManager.default.contentsOfDirectory(atPath: lib.path).first {
            packageRoot = lib.appendingPathComponent(first)
        } else {
            XCTFail("No LibriVox package written under \(exportDir).\n\(app.debugDescription)")
            return
        }

        let files = try? FileManager.default.contentsOfDirectory(at: packageRoot, includingPropertiesForKeys: nil)
        guard let files else {
            XCTFail("Could not read package directory \(packageRoot.path).\n\(app.debugDescription)")
            return
        }

        // One MP3 per exported section — exactly one for the single-chapter
        // scope.
        let mp3s = files.filter { $0.pathExtension == "mp3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(
            mp3s.count, 1,
            "Single-chapter export must contain exactly one MP3 (G11 regression); found \(mp3s.count)."
        )

        for mp3 in mp3s {
            // The Submit screen appears as the app finishes zipping, and the
            // freshly-encoded file may still be flushing on disk — poll rather
            // than false-failing a correct package on a partial read. A truly
            // wrong encoder setting (e.g. 192 kbps) never verifies and fails.
            var verified = false
            var data: Data?
            for _ in 0..<40 {
                if let d = try? Data(contentsOf: mp3),
                   MP3FrameParser.verifies(data: d, expectedKbps: 128, sampleRateHz: 44_100, mono: true) {
                    data = d
                    verified = true
                    break
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            XCTAssertTrue(
                verified,
                "\(mp3.lastPathComponent) is not 128 kbps CBR / 44.1 kHz / mono."
            )
            guard let data else { continue }
            let tags = try? ID3Reader.read(from: mp3)
            XCTAssertNotNil(tags, "\(mp3.lastPathComponent) has no readable ID3 tag")
            XCTAssertFalse(tags?.title?.isEmpty ?? true, "\(mp3.lastPathComponent) missing ID3 title")
            XCTAssertFalse(tags?.artist?.isEmpty ?? true, "\(mp3.lastPathComponent) missing ID3 artist")
            XCTAssertFalse(tags?.album?.isEmpty ?? true, "\(mp3.lastPathComponent) missing ID3 album")
            if let track = tags?.track {
                XCTAssertEqual(track.0, 1)
                XCTAssertEqual(track.1, 1)
            } else {
                XCTFail("\(mp3.lastPathComponent) missing ID3 track number")
            }
        }

        // Generated artifacts.
        let names = Set(files.map { $0.lastPathComponent })
        XCTAssertTrue(names.contains("librivox-checklist.md"), "checklist missing from package")
        XCTAssertTrue(names.contains("metadata.json"), "metadata.json missing from package")
        XCTAssertTrue(names.contains("checksums.sha256"), "checksums.sha256 missing from package")
        XCTAssertTrue(names.contains("section-durations.txt"), "section-durations.txt missing from package")

        // checksums.sha256 digests must match the files on disk.
        let checksumsURL = packageRoot.appendingPathComponent("checksums.sha256")
        let checksums = (try? String(contentsOf: checksumsURL, encoding: .utf8)) ?? ""
        for mp3 in mp3s {
            let data = try? Data(contentsOf: mp3)
            let digest = data.map { SHA256Hex.hex($0) }
            if let digest {
                XCTAssertTrue(
                    checksums.contains("\(digest)  \(mp3.lastPathComponent)"),
                    "checksums.sha256 does not contain the on-disk digest for \(mp3.lastPathComponent)"
                )
            }
        }
    }
}
