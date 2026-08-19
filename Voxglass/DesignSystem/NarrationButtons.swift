import SwiftUI

/// The one press appearance for narration controls. A press must be *visible*,
/// not merely felt: `.buttonStyle(.plain)` supplies no pressed state at all, so
/// approving a paragraph looked identical whether or not the tap landed
/// (field report 2026-08-19, item 1).
struct NarrationPressStyle: ButtonStyle {
    var haptics = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                // Only on press, and only through the button itself — the old
                // `.tactileTap()` gesture fired even on a disabled button.
                if isPressed, haptics { TactileFeedback.tap() }
            }
    }
}

/// Shared narration-flow call to action. Keeping the disabled explanation in
/// the component makes a blocked export understandable instead of merely dim.
struct NarrationPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isBusy = false
    var disabledReason: String? = nil
    let identifier: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(NarrationPalette.espresso) }
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
                .scaledFont(size: 15, weight: .heavy)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(NarrationPalette.espresso)
                .background(
                    LinearGradient(colors: [Palette.brass.opacity(0.85), Palette.brass], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
            .buttonStyle(NarrationPressStyle())
            .disabled(disabledReason != nil || isBusy)
            .accessibilityIdentifier(identifier)

            if let disabledReason {
                Text(disabledReason)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .accessibilityIdentifier("\(identifier).reason")
            }
        }
    }
}

struct NarrationSecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isBusy = false
    var disabledReason: String? = nil
    let identifier: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isBusy { ProgressView().tint(Palette.brass) }
                    if let systemImage { Image(systemName: systemImage) }
                    Text(title)
                }
                .scaledFont(size: 15, weight: .heavy)
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(Palette.brass)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.brass.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(NarrationPressStyle())
            .disabled(disabledReason != nil || isBusy)
            .accessibilityIdentifier(identifier)

            if let disabledReason {
                Text(disabledReason)
                    .scaledFont(size: 11.5)
                    .foregroundStyle(Palette.ink3)
                    .accessibilityIdentifier("\(identifier).reason")
            }
        }
    }
}
