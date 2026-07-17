import SwiftUI
import VoxglassCore

/// Launch splash ported from the radio app's `SplashView`: spring fade-in,
/// 1.5 s hold, 0.35 s ease-out handoff via `isPresented`. Distinct from the
/// onboarding `SplashView`, which is the "Get Started" welcome screen.
struct AnimatedSplashView: View {
    @Binding var isPresented: Bool

    @State private var opacity: Double = 0
    @State private var scale: CGFloat = 0.82
    @State private var iconScale: CGFloat = 0.7

    var body: some View {
        ZStack {
            VoxglassTheme.libraryBackground
        }
        .ignoresSafeArea()
        .overlay {
            VStack(spacing: 20) {
                Image(systemName: "books.vertical.fill")
                    .scaledFont(size: 80, weight: .light)
                    .foregroundStyle(Palette.brass)
                    .scaleEffect(iconScale)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("Voxglass")
                        .scaledFont(size: 38, weight: .bold, design: .rounded)
                        .foregroundStyle(Palette.ink)

                    Text("Public-domain audiobooks, private by default.")
                        .scaledFont(size: 15)
                        .foregroundStyle(Palette.ink2)
                }
                .scaleEffect(scale)
            }
            .accessibilityElement(children: .combine)
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                opacity = 1
                scale = 1
                iconScale = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    isPresented = false
                }
            }
        }
    }
}

#Preview {
    AnimatedSplashView(isPresented: .constant(true))
}
