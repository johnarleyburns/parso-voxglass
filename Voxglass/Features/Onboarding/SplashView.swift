import SwiftUI

struct SplashView: View {
    var continueAction: () -> Void

    var body: some View {
        ZStack {
            VoxglassTheme.libraryBackground.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 24)

                coverStack

                VStack(spacing: 10) {
                    Text("Voxglass")
                        .font(.system(size: 31, weight: .heavy, design: .default))
                        .kerning(-0.5)
                        .foregroundStyle(Palette.ink)
                    Text("Public-domain audiobooks with a private, local-first shelf.")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.ink2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(action: continueAction) {
                    Label("Get Started", systemImage: "sparkles")
                        .font(.system(size: 15.5, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .foregroundStyle(Color(hex: 0x221503))
                        .background {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                    startPoint: .top, endPoint: .bottom))
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
