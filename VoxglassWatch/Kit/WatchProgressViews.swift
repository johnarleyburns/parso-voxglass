import SwiftUI

/// Watch redesign §3 — a read-only 3 pt progress line. No scrubbing on the watch.
struct WatchProgressHairline: View {
    let fraction: Double
    var tint: Color = .primary

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: max(0, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A ring that closes with real progress, or a spinner before there is any (§3 `TransferRing`).
struct WatchTransferRing: View {
    let fraction: Double?
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(WatchPalette.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: fraction)
            } else {
                ProgressView().scaleEffect(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text("Progress"))
        .accessibilityValue(fraction.map { Text("\(Int(($0 * 100).rounded())) percent") } ?? Text("Starting"))
    }
}

/// A 3:4 book cover from the projection's artwork URL, with a gold gradient placeholder.
struct WatchCoverTile: View {
    let artworkKey: String?
    var width: CGFloat = 24

    var body: some View {
        Group {
            if let url = artworkKey.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: width * 4 / 3)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.18, style: .continuous))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [WatchPalette.accent.opacity(0.85), WatchPalette.accentSoft],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "book.closed").font(width > 30 ? .body : .caption2).foregroundStyle(.white.opacity(0.85))
        }
    }
}
