import SwiftUI
import VoxglassCore

struct CollectionFan: View {
    let books: [(title: String, author: String?)]
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(Array(books.prefix(3).enumerated()), id: \.offset) { index, book in
                CoverPlate(title: book.title, author: book.author, coverURL: nil, size: 72, shape: .portrait)
                    .frame(width: 72, height: 101)
                    .rotationEffect(.degrees([-10, -2, 8][index]))
                    .offset(x: CGFloat(index) * -21, y: CGFloat(index) * 4)
            }
        }
        .frame(width: 145, height: 112, alignment: .topTrailing)
    }
}
