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
        LinearGradient(colors: [Palette.surface, Palette.bg],
                       startPoint: .top, endPoint: .bottom)
    }

    static var warmBackground: LinearGradient {
        LinearGradient(colors: [Palette.raised, Palette.bg], startPoint: .top, endPoint: .bottom)
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
            let isLight = traits.userInterfaceStyle == .light
            let hex: UInt32
            if isLight {
                hex = traits.accessibilityContrast == .high ? pair.lightHighContrast : pair.light
            } else {
                hex = traits.accessibilityContrast == .high ? pair.highContrast : pair.standard
            }
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
    static let brassDeep = dynamic(PaletteSpec.Pair(
        standard: 0xB97F2E,
        highContrast: 0xD99A3C,
        light: 0x704600,
        lightHighContrast: 0x553300
    ))
    static let ok = dynamic(PaletteSpec.Pair(
        standard: 0x4CD471,
        highContrast: 0x7AE99A,
        light: 0x16733A,
        lightHighContrast: 0x0B5428
    ))
    static let danger = dynamic(PaletteSpec.Pair(
        standard: 0xFF6B5E,
        highContrast: 0xFFAAA2,
        light: 0xB42318,
        lightHighContrast: 0x8E1710
    ))
    static let hairline = Color(uiColor: UIColor { traits in
        let alpha = traits.accessibilityContrast == .high ? PaletteSpec.hairlineAlpha.highContrast : PaletteSpec.hairlineAlpha.standard
        let base = traits.userInterfaceStyle == .light ? UIColor.black : UIColor.white
        return base.withAlphaComponent(alpha)
    })
    static let surface = dynamic(PaletteSpec.surface)
    static let raised = dynamic(PaletteSpec.raised)
    static let surfaceLine = Color(uiColor: UIColor { traits in
        let alpha = traits.accessibilityContrast == .high ? PaletteSpec.surfaceLineAlpha.highContrast : PaletteSpec.surfaceLineAlpha.standard
        let base = traits.userInterfaceStyle == .light ? UIColor.black : UIColor.white
        return base.withAlphaComponent(alpha)
    })
    static let scrim = Color(hex: 0x0A0B0D).opacity(0.92)
    static let onBrass = dynamic(PaletteSpec.Pair(
        standard: 0x21170B,
        highContrast: 0x120B03,
        light: 0xFFFFFF,
        lightHighContrast: 0xFFFFFF
    ))
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
                .navigationTitle(LocalizedStringKey(title))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if let headerActionTitle, let headerAction {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(LocalizedStringKey(headerActionTitle), action: headerAction)
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
                            Button(LocalizedStringKey(headerSecondaryActionTitle), action: headerSecondaryAction)
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
