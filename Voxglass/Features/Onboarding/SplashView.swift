import SwiftUI

struct SplashView: View {
    var continueAction: () -> Void

    var body: some View {
        ZStack {
            VoxglassTheme.deepGlass.ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    VoxglassTheme.accent.opacity(0.18),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 24)

                coverStack

                VStack(spacing: 10) {
                    Text("Voxglass")
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Public-domain audiobooks with a private, local-first shelf.")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(action: continueAction) {
                    Label("Get Started", systemImage: "sparkles")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .foregroundStyle(VoxglassTheme.deepGlass)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(VoxglassTheme.accent)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Get started")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
    }

    private var coverStack: some View {
        ZStack {
            BookArtworkView(title: "Mystery Classics", size: 132)
                .rotationEffect(.degrees(-9))
                .offset(x: -58, y: 20)
                .opacity(0.82)
            BookArtworkView(title: "Golden Age Science Fiction", size: 148)
                .rotationEffect(.degrees(7))
                .offset(x: 58, y: 14)
                .opacity(0.88)
            BookArtworkView(title: "Voxglass", size: 164)
                .shadow(color: .black.opacity(0.35), radius: 28, y: 18)
        }
        .frame(height: 250)
        .accessibilityHidden(true)
    }
}
