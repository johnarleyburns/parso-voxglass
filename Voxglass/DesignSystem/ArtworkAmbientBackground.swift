import SwiftUI
import VoxglassCore

/// A quiet artwork-derived mesh used behind the Now Playing surface.
struct ArtworkAmbientBackground: View {
    let palette: ArtworkPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var drift = false

    var body: some View {
        if reduceTransparency {
            color(for: palette.deep)
        } else {
            MeshGradient(
                width: 3,
                height: 3,
                points: points,
                colors: colors
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
                    drift = true
                }
            }
        }
    }

    private var points: [SIMD2<Float>] {
        let offset: Float = drift && !reduceMotion ? 0.04 : 0
        return [
            [0, 0], [0.5, offset], [1, 0],
            [0, 0.5], [0.5 + offset, 0.5], [1, 0.5 - offset],
            [0, 1], [0.5 - offset, 1], [1, 1]
        ]
    }

    private var colors: [Color] {
        let deep = color(for: palette.deep)
        let dominant = color(for: palette.dominant)
        let vivid = color(for: palette.vivid)
        return [deep, deep, deep, dominant, vivid, dominant, deep, deep, deep]
    }

    private func color(for rgb: PlateRGB) -> Color {
        Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
