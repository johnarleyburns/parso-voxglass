import SwiftUI

/// A solid content surface. Liquid Glass is reserved for navigation chrome.
struct RaisedSurface: ViewModifier {
    let tint: Color?
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Palette.surface)
                    .overlay {
                        if let tint {
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
