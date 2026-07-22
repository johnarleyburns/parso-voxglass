import SwiftUI
import VoxglassCore

struct AnimatedSplashView: View {
    @Binding var isPresented: Bool

    @State private var opacity: Double = 0
    @State private var scale: Double = 0.82
    @State private var tileScale: CGFloat = 0.7

    var body: some View {
        ZStack {
            VoxglassTheme.libraryBackground

            Image("splash")
                .resizable()
                .scaledToFill()

            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
        .overlay {
            VStack(spacing: 16) {
                PeriodicTileView(
                    atomicNumber: "23",
                    symbol: "V",
                    name: "Voxglass",
                    atomicWeight: "50.942"
                )
                .scaleEffect(tileScale)

                Text("Public-domain audiobooks, private by default.")
                    .scaledFont(size: 15)
                    .foregroundStyle(.white.opacity(0.85))
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

struct PeriodicTileView: View {
    let atomicNumber: String
    let symbol: String
    let name: String
    let atomicWeight: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(atomicNumber)
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(.white)
                Spacer()
            }

            Spacer(minLength: 0)

            Text(symbol)
                .scaledFont(size: 42, weight: .bold)
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text(name)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(.white)

            Text(atomicWeight)
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(.white.opacity(0.82))
                .padding(.top, 2)
        }
        .padding(10)
        .frame(width: 110, height: 120)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.32))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.82), lineWidth: 1.5)
        }
    }
}

#Preview {
    AnimatedSplashView(isPresented: .constant(true))
}
