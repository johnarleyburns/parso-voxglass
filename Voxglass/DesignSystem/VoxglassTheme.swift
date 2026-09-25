import SwiftUI
import VoxglassCore

enum VoxglassTheme {
    static let paper = Color(hex: 0x0A0B0D)
    static let paperRaised = Color(hex: 0x1B1D22)
    static let ink = Color(hex: 0xF2F4F6)
    static let secondaryInk = Palette.ink2
    static let accent = Palette.brass
    static let deepGlass = Color(hex: 0x1B1D22)
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
    static let bg = Color(hex: 0x0A0B0D)
    static let ink = Color(hex: 0xF2F4F6)
    static let ink2 = Color(white: 0.92).opacity(0.58)
    // Keep tertiary text readable on both the dark background and raised
    // material surfaces. The previous translucent value fell below AA for
    // the small metadata labels used throughout the app.
    static let ink3 = Color(hex: 0xAEB2B8)
    static let brass = Color(hex: 0xE3A44B)
    static let brassDeep = Color(hex: 0xB97F2E)
    static let ok = Color(hex: 0x4CD471)
    static let danger = Color(hex: 0xFF6B5E)
    static let hairline = Color.white.opacity(0.10)
    static let surface = Color(hex: 0x17191D)
    static let surfaceLine = Color.white.opacity(0.08)
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
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
