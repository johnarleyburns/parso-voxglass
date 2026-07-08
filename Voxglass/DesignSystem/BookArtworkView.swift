import SwiftUI

struct BookArtworkView: View {
    var title: String
    var size: CGFloat = 68

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.125, green: 0.118, blue: 0.102),
                            Color(red: 0.500, green: 0.318, blue: 0.188),
                            VoxglassTheme.accent
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
            VStack(spacing: 5) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: max(18, size * 0.22), weight: .semibold))
                Text(initials)
                    .font(.system(size: max(12, size * 0.14), weight: .bold, design: .serif))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.65)
            }
            .foregroundStyle(Color(red: 1.0, green: 0.865, blue: 0.620))
            .padding(8)
        }
        .frame(width: size, height: size * 1.28)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = title
            .split(separator: " ")
            .prefix(3)
            .compactMap(\.first)
        let value = String(parts)
        return value.isEmpty ? "VG" : value.uppercased()
    }
}

