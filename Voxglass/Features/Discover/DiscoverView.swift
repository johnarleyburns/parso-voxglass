import SwiftUI

struct DiscoverView: View {
    var body: some View {
        VoxglassScreen(title: "Discover") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Public Domain")
                    .font(.system(.title2, design: .serif, weight: .bold))
                    .foregroundStyle(VoxglassTheme.ink)
                    .padding(.top, 12)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    DiscoverTile(title: "Fiction", systemImage: "book.closed", tint: .brown)
                    DiscoverTile(title: "Mystery", systemImage: "key.fill", tint: .orange)
                    DiscoverTile(title: "Poetry", systemImage: "quote.bubble.fill", tint: .purple)
                    DiscoverTile(title: "History", systemImage: "building.columns.fill", tint: .teal)
                    DiscoverTile(title: "Science", systemImage: "atom", tint: .blue)
                    DiscoverTile(title: "Philosophy", systemImage: "brain.head.profile", tint: .indigo)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Internet Archive")
                        .font(.headline)
                        .foregroundStyle(VoxglassTheme.ink)
                    Text("LibriVox audiobooks and archive.org URLs")
                        .font(.subheadline)
                        .foregroundStyle(VoxglassTheme.secondaryInk)
                }
                .padding(14)
                .glassPanel()
            }
        }
    }
}

private struct DiscoverTile: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(VoxglassTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
        .glassPanel()
    }
}
