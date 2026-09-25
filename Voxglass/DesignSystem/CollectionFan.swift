import SwiftUI
import VoxglassCore

struct CollectionFan: View {
    let books: [(title: String, author: String?)]
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(books.prefix(3).enumerated()), id: \.offset) { index, book in
                CoverPlate(title: book.title, author: book.author, coverURL: nil, size: 60, shape: .portrait)
                    .frame(width: 60, height: 86)
                    .rotationEffect(.degrees([-10, -2, 8][index]))
                    .offset(x: CGFloat(index) * -18, y: CGFloat(index) * 4)
            }
        }
        .frame(width: 120, height: 100, alignment: .topTrailing)
    }
}
