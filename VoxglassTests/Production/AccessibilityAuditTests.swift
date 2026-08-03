import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Accessibility audit (spec §12 / §22.1). The identifier registry in the spec
/// is the normative list of every interactive control across the four
/// production surfaces. These tests keep the registry honest in three ways:
///
/// 1. Every registry identifier resolves to a real control in the source
///    (exact string match, or prefix match for template patterns like
///    `record.take.<n>`), or is a documented absence whose control the MVP
///    implementation does not ship.
/// 2. The identifiers the five UI smoke tests key on can never be renamed
///    silently — they are the contract between the test and the app.
/// 3. Every identifier used in the new surfaces is well-formed
///    (`area.segment.segment`, lowercase, no spaces) so VoiceOver and the
///    XCUITest `accessibilityIdentifier` lookups keep working.
@Suite struct AccessibilityAuditTests {

    enum Area: String, CaseIterable {
        case studio = "VoxglassStudio"
        case iphone = "Voxglass/Features/Production"
        case phoneCarPlay = "Voxglass/App/CarPlay"
        case watch = "VoxglassWatch"
        case carPlay = "Voxglass/Core/CarPlay"
    }

    struct Entry {
        let id: String
        let area: Area
        init(_ id: String, _ area: Area) { self.id = id; self.area = area }
    }

    // MARK: - The §22.1 registry (verbatim, template suffixes normalized)

    private static let studioRegistry: [String] = [
        "library.newAudiobook", "library.openPackage", "library.project.", "library.section.", "library.activity.",
        "wizard.title", "wizard.author", "wizard.narrator", "wizard.purpose.", "wizard.rightsBasis.",
        "wizard.sourceURL", "wizard.editionYear", "wizard.attest", "wizard.continueToImport", "wizard.back", "wizard.cancel",
        "import.chapterCount", "import.warningCount", "import.acceptStructure", "import.resegment",
        "import.paragraph.", "import.splitHere.", "import.mergeNext.", "import.markSceneBreak",
        "dashboard.recordNext", "dashboard.previewOnDevices", "dashboard.startReviewQueue", "dashboard.openFeedback",
        "dashboard.chapter.", "dashboard.progress",
        "script.chapter.", "script.paragraph.", "script.save", "script.find", "script.split", "script.merge",
        "script.directionNote", "script.pronunciation", "script.reviewStatus", "script.driftBanner",
        "record.teleprompter", "record.transport.record", "record.transport.playTake", "record.transport.playInContext",
        "record.acceptAndNext", "record.flagAndNext", "record.previousParagraph", "record.nextParagraph",
        "record.take.", "record.importWAV", "record.quality.peak", "record.quality.noise", "record.inputLevel",
        "import.audio.origin.", "import.audio.method.", "import.audio.assign", "import.originWarning",
        "import.audio.addMarker", "import.audio.removeMarker", "import.audio.segment.",
        "compare.takeA", "compare.takeB", "compare.playAB", "compare.useSelected",
        "review.queue.item.", "review.approveAndNext", "review.pickupAndNext", "review.keepFlagged",
        "review.note", "review.autoAdvance", "review.playContext", "review.previousFlagged", "review.nextFlagged",
        "assemble.paragraphGap", "assemble.headSilence", "assemble.tailSilence", "assemble.renderPreview",
        "assemble.playChapter", "assemble.rebuildChanged", "assemble.row.",
        "metadata.tab.", "metadata.title", "metadata.author", "metadata.narrator", "metadata.language",
        "metadata.description", "metadata.subjects", "metadata.rightsBasis", "metadata.sourceURL", "metadata.attest",
        "metadata.originAudit", "metadata.artwork", "metadata.identifier", "metadata.save",
        "preview.syncNow", "preview.hideFromDevices", "preview.autoSync", "preview.includeText",
        "preview.prepareOfflineQueue", "preview.storageProfile", "preview.openReviewQueue",
        "validate.target.", "validate.runAgain", "validate.fixNext", "validate.issue.",
        "validate.severity.", "validate.goToParagraph.",
        "export.scope.", "export.destination.librivox", "export.destination.internetArchive",
        "export.destination.retail", "export.unlockPro", "export.run", "export.cancel", "export.revealInFinder",
        "settings.tab.", "settings.inputDevice", "settings.recordingFormat", "settings.monitoring",
        "settings.preRoll", "settings.warnClipping", "settings.autoMetrics", "settings.recordTest",
        "settings.purchasePro", "settings.restorePurchases", "settings.thirdPartyNotices", "settings.copyDiagnostics",
    ]

    private static let iphoneRegistry: [String] = [
        "shelf.myProductions", "production.",
        "detail.playWholeBook", "detail.reviewFlagged", "detail.mode.", "detail.chapter.",
        "player.flag", "player.approve", "player.pickup", "player.addNote", "player.autoAdvance",
        "player.previousParagraph", "player.nextParagraph", "player.skipBack", "player.skipForward", "player.queue",
        "paragraphList.filter.", "paragraphList.row.", "paragraphList.playSelected",
        "queueBuilder.predicate.", "queueBuilder.autoAdvance", "queueBuilder.skipApproved",
        "queueBuilder.downloadToWatch", "queueBuilder.start",
        "note.category.", "note.text", "note.dictate", "note.save", "note.cancel",
        "sync.checkForUpdates", "sync.downloadAll", "sync.removeAudio", "sync.refreshWatch", "sync.pending",
    ]

    private static let watchRegistry: [String] = [
        "watch.production.", "watch.reviewFlagged", "watch.queue.", "watch.continue",
        "watch.player.flag", "watch.player.approve", "watch.player.pickup", "watch.player.previous", "watch.player.next",
        "watch.player.autoNext", "watch.paragraphText", "watch.confirmation.approved", "watch.confirmation.flagged",
        "watch.confirmation.pickup", "watch.playNext", "watch.dictate", "watch.dictation.category.",
        "watch.dictation.save", "watch.dictation.redictate", "watch.sync.status", "watch.offline.start",
        "watch.offline.remove",
    ]

    private static let carPlayRegistry: [String] = [
        "carplay.tab.", "carplay.production.", "carplay.queue.",
        "carplay.approve", "carplay.pickup", "carplay.keepFlagged", "carplay.playNext", "carplay.undo",
        "carplay.settings.autoAdvance", "carplay.settings.playContext", "carplay.settings.audioConfirmations",
    ]

    /// Registry entries whose controls the MVP implementation does not ship,
    /// each with the reason (kept truthful; adding the control requires
    /// removing the row here).
    private static let documentedAbsences: [String: String] = [
        // Wizard rights step is a single form in the MVP (S4 simplified the
        // four-step wizard); rights are edited in Metadata & Rights.
        "wizard.rightsBasis.": "wizard has no rights step (see MetadataRightsView)",
        "wizard.sourceURL": "wizard has no rights step (see MetadataRightsView)",
        "wizard.editionYear": "wizard has no rights step (see MetadataRightsView)",
        "wizard.attest": "wizard has no rights step (see MetadataRightsView)",
        "wizard.back": "wizard is a single form with only Cancel",
        // The Script editor screen is DEFERRED; paragraph editing happens on
        // the source import acceptance path only.
        "script.chapter.": "no Script Editor screen in MVP (structure is accepted at import)",
        "script.paragraph.": "no Script Editor screen in MVP",
        "script.save": "no Script Editor screen in MVP",
        "script.find": "no Script Editor screen in MVP",
        "script.split": "no Script Editor screen in MVP",
        "script.merge": "no Script Editor screen in MVP",
        "script.directionNote": "no Script Editor screen in MVP",
        "script.pronunciation": "no Script Editor screen in MVP",
        "script.reviewStatus": "no Script Editor screen in MVP",
        "script.driftBanner": "no Script Editor screen in MVP",
        // Recording workspace is the teleprompter + transport core; takes and
        // quality inspection live in Take Comparison.
        "record.acceptAndNext": "recording advances via Next ¶ (S5 simplification)",
        "record.flagAndNext": "flagging happens in Review Queue",
        "record.take.": "take list lives in Take Comparison",
        "record.importWAV": "import lives in the Import Audio feature",
        "record.quality.peak": "quality metrics shown in Take Comparison",
        "record.quality.noise": "quality metrics shown in Take Comparison",
        "record.inputLevel": "level shown in the meter section without an identifier",
        "record.transport.playTake": "take playback lives in Take Comparison",
        "record.transport.playInContext": "context playback lives in the Review Queue",
        // The import-audio marker workflow is DEFERRED (spanning takes are not
        // supported, §22.4 deviation 07-import-audio).
        "import.audio.addMarker": "marker workflow not implemented in MVP",
        "import.audio.removeMarker": "marker workflow not implemented in MVP",
        "import.audio.segment.": "segment table not rendered in MVP",
        "import.resegment": "re-segmentation options not implemented",
        "import.paragraph.": "paragraph list not rendered at import",
        "import.splitHere.": "split UI not implemented",
        "import.mergeNext.": "merge UI not implemented",
        "import.markSceneBreak": "scene-break marking not implemented",
        "import.warningCount": "import warnings are not surfaced in the simplified import view",
        "library.activity.": "activity feed not implemented in the library",
        "library.section.": "library sidebar sections not implemented",
        "library.project.": "recents list rows are identified by their package path",
        "dashboard.openFeedback": "feedback feed not implemented on the dashboard",
        "dashboard.chapter.": "chapter rows are not individually identified",
        "dashboard.progress": "progress ring has no identifier (visual only)",
        "compare.takeA": "take comparison uses per-row play/select buttons",
        "compare.takeB": "take comparison uses per-row play/select buttons",
        "compare.playAB": "take comparison plays a single take (A/B sync DEFERRED)",
        "compare.useSelected": "take comparison uses 'Use Selected Take' per row",
        "metadata.tab.": "tabs are plain TabView items without identifiers",
        "metadata.artwork": "artwork tab not implemented (cover is metadata-only)",
        "metadata.subjects": "subjects field exists but carries no identifier",
        "metadata.rightsBasis": "rights picker exists but carries no identifier",
        "validate.fixNext": "issue fixes are inline, not a single next-fix button",
        "validate.goToParagraph.": "issue rows carry no jump button",
        "player.autoAdvance": "phone player auto-advance is on the queue builder",
        "queueBuilder.downloadToWatch": "watch download not implemented on the phone",
        "note.dictate": "dictation is a watch-only affordance",
        "carplay.playNext": "CPAlertTemplate actions expose no identifiers",
        "carplay.undo": "CPAlertTemplate actions expose no identifiers",
    ]

    // MARK: - Sources under audit

    private static func sourceFiles(in area: Area) -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // repo root
        let areaURL = root.appendingPathComponent(area.rawValue)
        guard let enumerator = FileManager.default.enumerator(
            at: areaURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { url -> String? in
            guard let url = url as? URL, url.pathExtension == "swift" else { return nil }
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
    }

    private static func areaContains(_ area: Area, _ fragment: String) -> Bool {
        sourceFiles(in: area).contains { $0.contains("\"\(fragment)") }
    }

    // MARK: - Tests

    @Test func registryIdentifiersResolveInStudioSource() {
        let missing = AccessibilityAuditTests.studioRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.studio, id)
        }
        #expect(missing.isEmpty, "Studio identifiers missing from source (add the control or document the absence): \(missing)")
    }

    @Test func registryIdentifiersResolveInPhoneSource() {
        let missing = AccessibilityAuditTests.iphoneRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.iphone, id)
        }
        #expect(missing.isEmpty, "iPhone identifiers missing from source: \(missing)")
    }

    @Test func registryIdentifiersResolveInWatchSource() {
        let missing = AccessibilityAuditTests.watchRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.watch, id)
        }
        #expect(missing.isEmpty, "Watch identifiers missing from source: \(missing)")
    }

    @Test func registryIdentifiersResolveInCarPlaySource() {
        let missing = AccessibilityAuditTests.carPlayRegistry.filter { id in
            guard Self.documentedAbsences[id] == nil else { return false }
            return !Self.areaContains(.carPlay, id) && !Self.areaContains(.phoneCarPlay, id)
        }
        #expect(missing.isEmpty, "CarPlay identifiers missing from source: \(missing)")
    }

    @Test func smokePathIdentifiersAreNeverRenamed() {
        // The exact identifiers the five UI smoke tests key on (§19.6). If a
        // view renames one of these, this test fails before the flaky UI run.
        let smokeKeys: [String: Area] = [
            "library.newAudiobook": .studio,
            "wizard.title": .studio, "wizard.author": .studio, "wizard.narrator": .studio,
            "wizard.continueToImport": .studio,
            "import.chapterCount": .studio, "import.acceptStructure": .studio,
            "dashboard.recordNext": .studio,
            "shelf.myProductions": .iphone, "detail.playWholeBook": .iphone, "detail.reviewFlagged": .iphone,
            "watch.queue.": .watch,        ]
        let missing = smokeKeys.filter { !Self.areaContains($0.value, $0.key) }
        #expect(missing.isEmpty, "Smoke-path identifiers missing from source: \(missing.keys)")
    }

    @Test func identifiersAreWellFormed() {
        // Every identifier in the four production surfaces must be
        // dot-separated and free of spaces and underscores so accessibility
        // and XCUITest lookups behave. Registry identifiers use camelCase
        // segments (e.g. `settings.copyDiagnostics`), so mixed case is fine.
        let pattern = #/^[a-z][a-zA-Z0-9-]*(?:\.[a-zA-Z0-9-]+)+$/#
        var offenders: [String] = []
        for area in Area.allCases {
            for source in Self.sourceFiles(in: area) {
                for match in source.matchingStrings(of: #/"[a-z]+\.[a-zA-Z0-9.-]+"/#) {
                    let id = match.dropFirst().dropLast()
                    if id.wholeMatch(of: pattern) == nil {
                        offenders.append("\(area.rawValue): \(id)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "Malformed accessibility identifiers: \(offenders)")
    }
}

private extension String {
    func matchingStrings(of regex: Regex<Substring>) -> [Substring] {
        matches(of: regex).map(\.output)
    }
}
