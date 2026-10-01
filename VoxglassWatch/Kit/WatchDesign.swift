import SwiftUI

/// Watch redesign §3 (`docs/plans/watch-redesign/DESIGN.md`) — the Watch Listening Kit tokens,
/// shared in shape with Platterhead's watch app; Voxglass uses its gold accent. Text uses semantic
/// styles only; the fixed numbers are minimum hit targets.
enum WatchPalette {
    /// Voxglass gold (`#D8AD67`, `--gold` in `docs/mockups/_shared.css`).
    static let accent = Color(red: 0xD8 / 255, green: 0xAD / 255, blue: 0x67 / 255)
    static let accentInk = Color(red: 0x1A / 255, green: 0x11 / 255, blue: 0x08 / 255)
    static let accentSoft = Color(red: 0x35 / 255, green: 0x2A / 255, blue: 0x19 / 255)
    static let surface = Color(red: 0x1E / 255, green: 0x22 / 255, blue: 0x24 / 255)
    static let surfaceRaised = Color(red: 0x2B / 255, green: 0x30 / 255, blue: 0x33 / 255)
    static let ink = Color(red: 0xF7 / 255, green: 0xF0 / 255, blue: 0xE6 / 255)
    static let success = Color(red: 0x4C / 255, green: 0xD4 / 255, blue: 0x71 / 255)
    static let warning = Color(red: 0xFF / 255, green: 0xCC / 255, blue: 0x5C / 255)
    static let failure = Color(red: 0xE2 / 255, green: 0x70 / 255, blue: 0x5F / 255)
    static let control = Color.white.opacity(0.08)
}

enum WatchMetrics {
    static let playButton: CGFloat = 58
    static let sideButton: CGFloat = 44
    static let toolButton: CGFloat = 30
    static let pillHeight: CGFloat = 40
    static let smallPillHeight: CGFloat = 34
}

enum WatchTimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    /// "6h 12m", "12m", "45s".
    static func short(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0m" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return String(localized: "\(hours)h \(minutes)m") }
        if minutes > 0 { return String(localized: "\(minutes)m") }
        return String(localized: "\(total)s")
    }
}

extension View {
    /// The inset card row used by every redesigned list.
    func watchCardRow(current: Bool = false) -> some View {
        listRowBackground(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(current ? WatchPalette.accentSoft : WatchPalette.surface))
    }
}

extension View {
    /// Double Tap (Series 9+/Ultra 2) as this screen's primary action, where the OS supports it.
    @ViewBuilder
    func watchPrimaryActionShortcut() -> some View {
        if #available(watchOS 11.0, *) {
            handGestureShortcut(.primaryAction)
        } else {
            self
        }
    }
}
