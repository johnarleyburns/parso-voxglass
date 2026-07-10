import SwiftUI
import UIKit

enum VoxglassTheme {
    static let paper = adaptiveColor(
        light: UIColor(red: 0.965, green: 0.941, blue: 0.902, alpha: 1),
        dark: UIColor(red: 0.035, green: 0.043, blue: 0.042, alpha: 1)
    )
    static let paperRaised = adaptiveColor(
        light: UIColor(red: 0.992, green: 0.976, blue: 0.948, alpha: 1),
        dark: UIColor(red: 0.075, green: 0.083, blue: 0.080, alpha: 1)
    )
    static let ink = adaptiveColor(
        light: UIColor(red: 0.082, green: 0.074, blue: 0.066, alpha: 1),
        dark: UIColor(red: 0.965, green: 0.936, blue: 0.875, alpha: 1)
    )
    static let secondaryInk = adaptiveColor(
        light: UIColor(red: 0.388, green: 0.341, blue: 0.292, alpha: 1),
        dark: UIColor(red: 0.695, green: 0.660, blue: 0.590, alpha: 1)
    )
    static let accent = Color(red: 0.886, green: 0.635, blue: 0.361)
    static let deepGlass = Color(red: 0.030, green: 0.035, blue: 0.034)
    static let softLine = adaptiveColor(
        light: UIColor.black.withAlphaComponent(0.08),
        dark: UIColor.white.withAlphaComponent(0.11)
    )
    static let warmLine = Color(red: 0.886, green: 0.635, blue: 0.361).opacity(0.30)

    static func backgroundGradient(for colorScheme: ColorScheme) -> LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.030, green: 0.037, blue: 0.036),
                    Color(red: 0.055, green: 0.065, blue: 0.061),
                    Color(red: 0.145, green: 0.105, blue: 0.070)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        return LinearGradient(
            colors: [
                Color(red: 0.992, green: 0.977, blue: 0.950),
                Color(red: 0.930, green: 0.902, blue: 0.858)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        })
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
                    content
                        .padding(.horizontal, 18)
                        .padding(.bottom, 110)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

struct VoxglassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceTransparency {
            VoxglassTheme.paper.ignoresSafeArea()
        } else {
            VoxglassTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
        }
    }
}

struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.paperRaised)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(VoxglassTheme.softLine, lineWidth: 1)
            }
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.08), radius: 16, y: 8)
    }
}

extension View {
    func glassPanel() -> some View {
        modifier(GlassPanel())
    }

    @ViewBuilder
    func motionAwareAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }
}

private struct MotionAwareAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}
