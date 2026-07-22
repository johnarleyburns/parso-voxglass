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

enum Palette {
    static let bg = Color(hex: 0x0A0B0D)
    static let ink = Color(hex: 0xF2F4F6)
    static let ink2 = Color(white: 0.92).opacity(0.58)
    static let ink3 = Color(white: 0.92).opacity(0.34)
    static let brass = Color(hex: 0xE3A44B)
    static let brassDeep = Color(hex: 0xB97F2E)
    static let ok = Color(hex: 0x4CD471)
    static let danger = Color(hex: 0xFF6B5E)
    static let hairline = Color.white.opacity(0.10)
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
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                VoxglassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(title)
                                .scaledFont(size: 31, weight: .heavy, design: .default)
                                .foregroundStyle(Palette.ink)
                            Spacer()
                        }
                        .padding(.horizontal, 2)
                        .padding(.top, 8)

                        content
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 160)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
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

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 18
    var strokeOpacity: Double = 0.13
    var fill: Color = Color.white.opacity(0.085)

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(reduceTransparency ? AnyShapeStyle(Color(hex: 0x1B1D22)) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(fill)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 18,
                      strokeOpacity: Double = 0.13,
                      fill: Color = Color.white.opacity(0.085)) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, strokeOpacity: strokeOpacity, fill: fill))
    }

    func glassPanel() -> some View {
        modifier(GlassSurface())
    }

    func tactileTap() -> some View {
        simultaneousGesture(TapGesture().onEnded { TactileFeedback.tap() })
    }
}

public enum TactileFeedback {
    public static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
