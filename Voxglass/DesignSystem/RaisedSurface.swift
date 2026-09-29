import SwiftUI

/// A solid content surface. Liquid Glass is reserved for navigation chrome.
struct RaisedSurface: ViewModifier {
    let tint: Color?
    let radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(reduceTransparency ? VoxglassTheme.paperRaised : Palette.surface)
                    .overlay {
                        if !reduceTransparency, let tint {
                            RadialGradient(colors: [tint.opacity(0.38), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Palette.surfaceLine, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func raisedSurface(tint: Color? = nil, radius: CGFloat = Radius.card) -> some View {
        modifier(RaisedSurface(tint: tint, radius: radius))
    }
}
