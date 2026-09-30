import Foundation
import Testing

/// Regression guard for the watchOS icon that App Store Connect validates only
/// during archive export/upload. A normal `xcodebuild build` can succeed while
/// the runtime icon is absent, which later produces the opaque “Missing
/// CFBundleIconName”/“Missing Icons” TestFlight failure we have already hit.
///
/// The Watch icon is the watchOS circle (Icon Composer's 1088 canvas) of the shared
/// `Voxglass/Resources/AppIcon.icon`. If this test fails, restore that file with
/// watchOS enabled in Icon Composer, keep it in the VoxglassWatch target, and run:
/// `bash scripts/check_watch_app_icon.sh && swift test --filter WatchAppIconContractTests`.
@Suite struct WatchAppIconContractTests {
    private static let remediation = """
    WHAT TO DO: Restore Voxglass/Resources/AppIcon.icon with watchOS enabled under Icon Composer's platforms, keep it in the VoxglassWatch target's sources in project.yml, do not re-add a Watch AppIcon.appiconset (two icons named AppIcon clash), then run `bash scripts/check_watch_app_icon.sh` and `swift test --filter WatchAppIconContractTests`.
    """

    @Test func sharedIconDeclaresWatchCircleAndCompilesRuntimeIcon() throws {
        let iconURL = repoRoot.appendingPathComponent("Voxglass/Resources/AppIcon.icon")
        let manifestURL = iconURL.appendingPathComponent("icon.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return fail("WHY THIS TEST FAILS: The shared app icon manifest is missing or unreadable at \(manifestURL.path).")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let manifest = object as? [String: Any]
        else {
            return fail("WHY THIS TEST FAILS: AppIcon.icon/icon.json is not a valid JSON object.")
        }

        let platforms = manifest["supported-platforms"] as? [String: Any]
        let circles = platforms?["circles"] as? [String] ?? []
        #expect(circles.contains("watchOS"), Comment(rawValue: failureMessage("WHY THIS TEST FAILS: AppIcon.icon does not declare the watchOS circle, so the Watch app would ship without a runtime icon.")))

        let legacyWatchIconSet = repoRoot.appendingPathComponent("VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset")
        #expect(!FileManager.default.fileExists(atPath: legacyWatchIconSet.path), Comment(rawValue: failureMessage("WHY THIS TEST FAILS: A Watch AppIcon.appiconset exists alongside AppIcon.icon; two icons named AppIcon clash in the asset compile.")))

        let project = (try? String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)) ?? ""
        let watchTarget = project.components(separatedBy: "\n  VoxglassWatch:\n").dropFirst().first?
            .components(separatedBy: "\n  Voxglass").first ?? ""
        #expect(watchTarget.contains("path: Voxglass/Resources/AppIcon.icon"), Comment(rawValue: failureMessage("WHY THIS TEST FAILS: project.yml no longer lists AppIcon.icon in the VoxglassWatch target's sources.")))

        #if os(macOS)
        if let infoPlist = try compileForWatchOS(iconURL) {
            let icons = infoPlist["CFBundleIcons"] as? [String: Any]
            let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
            #expect(primary?["CFBundleIconName"] as? String == "AppIcon", Comment(rawValue: failureMessage("WHY THIS TEST FAILS: watchOS actool did not produce CFBundleIconName=AppIcon from AppIcon.icon; archive export would fail with a missing watch icon.")))
        }
        #endif
    }

    #if os(macOS)
    /// Returns the partial Info.plist actool writes, or nil when Xcode is unavailable
    /// (the manifest checks above still ran) or actool failed (recorded as a failure).
    private func compileForWatchOS(_ iconURL: URL) throws -> [String: Any]? {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-watch-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let partialPlist = output.appendingPathComponent("info.plist")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "actool", iconURL.path,
            "--compile", output.path,
            "--output-format", "human-readable-text",
            "--errors", "--warnings",
            "--output-partial-info-plist", partialPlist.path,
            "--app-icon", "AppIcon",
            "--target-device", "watch",
            "--minimum-deployment-target", "10.0",
            "--platform", "watchos",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: partialPlist) else {
            fail("WHY THIS TEST FAILS: watchOS actool rejected AppIcon.icon (exit \(process.terminationStatus)).")
            return nil
        }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    }
    #endif

    @Test func widgetExtensionPlistHasAppStoreRequiredMetadata() throws {
        let plistURL = repoRoot.appendingPathComponent("VoxglassWidgets/Info.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let plist = object as? [String: Any]
        else {
            return fail("WHY THIS TEST FAILS: The WidgetKit extension Info.plist is missing or invalid at \(plistURL.path).")
        }

        #expect(
            (plist["CFBundleDisplayName"] as? String)?.isEmpty == false,
            Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The widget extension has no CFBundleDisplayName, so App Store Connect rejects the upload."))
        )
        #expect(
            plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)",
            Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The widget extension version is not tied to MARKETING_VERSION, so it can diverge from the containing app during export."))
        )
        #expect(
            plist["CFBundleVersion"] as? String == "$(CURRENT_PROJECT_VERSION)",
            Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The widget extension build number is not tied to CURRENT_PROJECT_VERSION, so it can diverge from the containing app during export."))
        )
        let extensionPoint = (plist["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String
        #expect(
            extensionPoint == "com.apple.widgetkit-extension",
            Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The widget extension is missing NSExtensionPointIdentifier=com.apple.widgetkit-extension, so App Store Connect cannot identify it as a WidgetKit extension."))
        )
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func failureMessage(_ why: String) -> String {
        """
        (why)
        (Self.remediation)
        """
    }

    private func fail(_ why: String) {
        Issue.record(Comment(rawValue: failureMessage(why)))
    }
}
