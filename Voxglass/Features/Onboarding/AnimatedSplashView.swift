import SwiftUI
import VoxglassCore

/// Launch splash ported from the radio app's `SplashView`: spring fade-in,
/// 1.5 s hold, 0.35 s ease-out handoff via `isPresented`. Distinct from the
/// onboarding `SplashView`, which is the "Get Started" welcome screen.
///
/// Background is the `splash` imageset; the foreground is the periodic-table
/// tile for V (Vanadium), mirroring `scripts/make_icon.py`.
struct AnimatedSplashView: View {
    @Binding var isPresented: Bool

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.82
    @State private var tileScale: CGFloat = 0.7

    var body: some View {
        ZStack {
            VoxglassTheme.libraryBackground

            Image("splash")
                .resizable()
                .scaledToFill()

            LinearGradient(stops: [
                .init(color: Color.black.opacity(0.42), location: 0),
                .init(color: Color.black.opacity(0.58), location: 0.55),
                .init(color: Color.black.opacity(0.74), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .overlay {
            VStack(spacing: 22) {
                PeriodicTileView(
                    atomicNumber: "23",
                    symbol: "V",
                    name: "Voxglass",
                    atomicWeight: "50.942"
                )
                .scaleEffect(tileScale)

                Text("Public-domain audiobooks, private by default.")
                    .scaledFont(size: 15)
                    .foregroundStyle(Palette.ink2)
                    .scaleEffect(scale)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Voxglass. Public-domain audiobooks, private by default.")
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                opacity = 1
                scale = 1
                tileScale = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    isPresented = false
                }
            }
        }
    }
}

/// Periodic-table element tile matching the app icon: atomic number top-left,
/// large element symbol, app name, and atomic weight on a dark field with a
/// brass radial glow.
struct PeriodicTileView: View {
    let atomicNumber: String
    let symbol: String
    let name: String
    let atomicWeight: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(atomicNumber)
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundStyle(Palette.ink)
                Spacer()
            }

            Spacer(minLength: 0)

            Text(symbol)
                .scaledFont(size: 88, weight: .bold)
                .foregroundStyle(Palette.ink)

            Spacer(minLength: 0)

            Text(name)
                .scaledFont(size: 17)
                .foregroundStyle(Palette.ink)

            Text(atomicWeight)
                .scaledFont(size: 13)
                .foregroundStyle(Palette.ink2)
                .padding(.top, 3)
        }
        .padding(22)
        .frame(width: 224, height: 224)
        .background {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x12141A), Color(hex: 0x0A0B0D)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay {
                    RadialGradient(colors: [Palette.brass.opacity(0.30), .clear],
                                   center: UnitPoint(x: 0.28, y: 0.08),
                                   startRadius: 0, endRadius: 250)
                }
                .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                .shadow(color: Color.black.opacity(0.45), radius: 26, y: 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(Palette.brass.opacity(0.32), lineWidth: 1)
        }
    }
}

#Preview {
    AnimatedSplashView(isPresented: .constant(true))
}
