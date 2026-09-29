import SwiftUI
import UIKit
import VoxglassCore

enum VoxglassTheme {
    static let paper = Palette.bg
    static let paperRaised = Palette.raised
    static let ink = Palette.ink
    static let secondaryInk = Palette.ink2
    static let accent = Palette.brass
    static let deepGlass = Palette.raised
    static let softLine = Palette.hairline
    static let warmLine = Palette.brass.opacity(0.30)

    static let brass = Palette.brass
    static let brassDeep = Palette.brassDeep
    static let ink3 = Palette.ink3
    static let ok = Palette.ok
    static let danger = Palette.danger

    static var libraryBackground: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x101216), Color(hex: 0x0B0C0F)],
                       startPoint: .top, endPoint: .bottom)
    }

    static var warmBackground: LinearGradient {
        LinearGradient(stops: [
            .init(color: Color(hex: 0x241A10), location: 0),
            .init(color: Color(hex: 0x12100C), location: 0.34),
            .init(color: Color(hex: 0x0B0C0F), location: 0.70)
        ], startPoint: .top, endPoint: .bottom)
    }
}

enum VoxglassLayout {
    static let minimumControlHitTarget: CGFloat = 44
}

enum ChromeMetrics {
    static let minimumControlHitTarget: CGFloat = 44
}

enum Palette {
    private static func dynamic(_ pair: PaletteSpec.Pair) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.accessibilityContrast == .high ? pair.highContrast : pair.standard
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    static let bg = dynamic(PaletteSpec.bg)
    static let ink = dynamic(PaletteSpec.ink)
    static let ink2 = dynamic(PaletteSpec.ink2)
    static let ink3 = dynamic(PaletteSpec.ink3)
    static let brass = dynamic(PaletteSpec.brass)
    static let brassDeep = Color(hex: 0xB97F2E)
    static let ok = Color(hex: 0x4CD471)
    static let danger = Color(hex: 0xFF6B5E)
    static let hairline = Color(uiColor: UIColor { traits in
        UIColor.white.withAlphaComponent(traits.accessibilityContrast == .high ? PaletteSpec.hairlineAlpha.highContrast : PaletteSpec.hairlineAlpha.standard)
    })
    static let surface = dynamic(PaletteSpec.surface)
    static let raised = dynamic(PaletteSpec.raised)
    static let surfaceLine = Color(uiColor: UIColor { traits in
        UIColor.white.withAlphaComponent(traits.accessibilityContrast == .high ? PaletteSpec.surfaceLineAlpha.highContrast : PaletteSpec.surfaceLineAlpha.standard)
    })
    static let scrim = Color(hex: 0x0A0B0D).opacity(0.92)
    static let onBrass = Color(hex: 0x21170B)
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

struct VoxglassScreen<Content: View>: View {
    let title: String
    var embedsNavigationStack = true
    /// A screen can change its primary content surface (for example, from
    /// featured shelves to a collection result list). Resetting the shared
    /// scroll position keeps the first item fully visible instead of
    /// inheriting the previous surface's offset.
    var scrollToTopTrigger: AnyHashable? = nil
    var headerActionTitle: String?
    var headerAction: (() -> Void)?
    var headerSecondaryActionTitle: String?
    var headerSecondaryActionSystemImage: String?
    var headerSecondaryAction: (() -> Void)?
    var headerSecondaryActionAccessibilityLabel: String?
    /// Screens with more than two compact actions can provide one composed
    /// trailing group while keeping the shared title/header geometry.
    var headerTrailingContent: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack { screenContent }
            } else {
                screenContent
            }
        }
    }

    private var screenContent: some View {
            ScrollViewReader { proxy in
                ScrollView {
                        content
                            .padding(.horizontal, Spacing.gutter)
                            .padding(.top, 8)
                            .padding(.bottom, Spacing.section)
                            // Keep the last row scrollable above the tab bar
                            // and the optional tab-view bottom accessory on
                            // compact devices. Plain padding is not included
                            // in the system safe-area inset used by ScrollView.
                            .safeAreaPadding(.bottom, Spacing.section)
                            .id("voxglass.screen.content")
                }
                .background(VoxglassBackground())
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if let headerActionTitle, let headerAction {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(headerActionTitle, action: headerAction)
                                .accessibilityIdentifier(headerActionTitle)
                        }
                    }
                    if let headerSecondaryActionSystemImage, let headerSecondaryAction {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(action: headerSecondaryAction) {
                                Image(systemName: headerSecondaryActionSystemImage)
                            }
                            .accessibilityLabel(headerSecondaryActionAccessibilityLabel ?? "Action")
                        }
                    } else if let headerSecondaryActionTitle, let headerSecondaryAction {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(headerSecondaryActionTitle, action: headerSecondaryAction)
                                .accessibilityLabel(headerSecondaryActionAccessibilityLabel ?? headerSecondaryActionTitle)
                        }
                    }
                    if let headerTrailingContent {
                        ToolbarItemGroup(placement: .topBarTrailing) { headerTrailingContent }
                    }
                }
                .onChange(of: scrollToTopTrigger) { _, _ in
                    guard scrollToTopTrigger != nil else { return }
                    withAnimation(Motion.standard) { proxy.scrollTo("voxglass.screen.content", anchor: .top) }
                }
            }
    }
}

struct VoxglassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            VoxglassTheme.paper.ignoresSafeArea()
        } else {
            VoxglassTheme.libraryBackground.ignoresSafeArea()
        }
    }
}

extension View {
    func tactileTap() -> some View {
        simultaneousGesture(TapGesture().onEnded { TactileFeedback.tap() })
    }
}

public enum TactileFeedback {
    @MainActor public static func tap() {
        // Haptics are attached to user-initiated SwiftUI actions with
        // `.sensoryFeedback`, so remote commands and automatic transitions do
        // not accidentally vibrate the device.
    }
}
