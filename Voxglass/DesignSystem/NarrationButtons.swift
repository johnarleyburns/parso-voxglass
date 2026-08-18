import SwiftUI

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
            .buttonStyle(.plain)
            .tactileTap()
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
            .buttonStyle(.plain)
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
