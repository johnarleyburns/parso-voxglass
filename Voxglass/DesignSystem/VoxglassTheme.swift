import SwiftUI

enum VoxglassTheme {
    static let paper = Color(red: 0.965, green: 0.941, blue: 0.902)
    static let paperRaised = Color(red: 0.992, green: 0.976, blue: 0.948)
    static let ink = Color(red: 0.082, green: 0.074, blue: 0.066)
    static let secondaryInk = Color(red: 0.388, green: 0.341, blue: 0.292)
    static let accent = Color(red: 0.824, green: 0.565, blue: 0.322)
    static let deepGlass = Color(red: 0.075, green: 0.082, blue: 0.078)
    static let softLine = Color.black.opacity(0.08)

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.992, green: 0.977, blue: 0.950),
                Color(red: 0.930, green: 0.902, blue: 0.858)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct VoxglassScreen<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                if reduceTransparency {
                    VoxglassTheme.paper.ignoresSafeArea()
                } else {
                    VoxglassTheme.backgroundGradient.ignoresSafeArea()
                }

                ScrollView {
                    content
                        .padding(.horizontal, 18)
                        .padding(.bottom, 28)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
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
                        .fill(.thinMaterial)
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

