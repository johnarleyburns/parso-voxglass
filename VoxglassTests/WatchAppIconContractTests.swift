import Foundation
import Testing

/// Regression guard for the watchOS icon that App Store Connect validates only
/// during archive export/upload. A normal `xcodebuild build` can succeed while
/// the runtime icon is absent, which later produces the opaque “Missing
/// CFBundleIconName”/“Missing Icons” TestFlight failure we have already hit.
///
/// If this test fails, restore the `universal` and `watch-marketing` entries and
/// their 1024x1024 opaque PNG files in
/// `VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset`, then run:
/// `bash scripts/check_watch_app_icon.sh && swift test --no-parallel --filter WatchAppIconContractTests`.
@Suite struct WatchAppIconContractTests {
    private static let remediation = """
    WHAT TO DO: Restore the universal watchOS runtime icon and the watch-marketing icon as 1024x1024 opaque PNGs in VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset, then run `bash scripts/check_watch_app_icon.sh` and `swift test --no-parallel --filter WatchAppIconContractTests`.
    """

    @Test func manifestContainsUploadSafeRuntimeAndMarketingIcons() throws {
        let manifestURL = repoRoot
            .appendingPathComponent("VoxglassWatch/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return fail("WHY THIS TEST FAILS: The watch app icon Contents.json is missing or unreadable at \(manifestURL.path).")
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let manifest = object as? [String: Any],
            let images = manifest["images"] as? [[String: Any]]
        else {
            return fail("WHY THIS TEST FAILS: The watch app icon Contents.json is not a valid manifest with an images array.")
        }

        let runtime = images.filter {
            $0["idiom"] as? String == "universal"
                && $0["platform"] as? String == "watchos"
                && $0["size"] as? String == "1024x1024"
        }
        #expect(runtime.count == 1, Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The watchOS 10+ universal runtime icon entry is missing or duplicated; without exactly one entry, archive export can produce an iconless watch app.")))

        let marketing = images.filter {
            $0["idiom"] as? String == "watch-marketing"
                && $0["scale"] as? String == "1x"
                && $0["size"] as? String == "1024x1024"
        }
        #expect(marketing.count == 1, Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The watch-marketing 1024x1024 icon entry is missing or duplicated; App Store Connect requires it for the watch app listing.")))

        for (label, entry) in [("universal runtime", runtime.first), ("watch-marketing", marketing.first)] {
            guard let entry else { continue }
            guard let filename = entry["filename"] as? String, !filename.isEmpty else {
                return fail("WHY THIS TEST FAILS: The \(label) icon entry has no filename.")
            }
            let iconURL = manifestURL.deletingLastPathComponent().appendingPathComponent(filename)
            guard let iconData = try? Data(contentsOf: iconURL) else {
                return fail("WHY THIS TEST FAILS: The \(label) icon file is missing: \(iconURL.path).")
            }
            guard let png = PNGHeader(data: iconData) else {
                return fail("WHY THIS TEST FAILS: The \(label) icon is not a readable PNG: \(iconURL.path).")
            }
            #expect(
                png.width == 1024 && png.height == 1024,
                Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The \(label) icon must be exactly 1024x1024, but is \(png.width)x\(png.height)."))
            )
            #expect(
                !png.hasAlpha,
                Comment(rawValue: failureMessage("WHY THIS TEST FAILS: The \(label) icon has an alpha channel, which App Store Connect rejects during upload."))
            )
        }
    }

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

    private struct PNGHeader {
        let width: UInt32
        let height: UInt32
        let colorType: UInt8

        var hasAlpha: Bool { colorType == 4 || colorType == 6 }

        init?(data: Data) {
            let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            guard data.count >= 26, data.prefix(8) == signature, data.subdata(in: 12..<16) == Data("IHDR".utf8) else {
                return nil
            }
            width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            colorType = data[25]
        }
    }
}
