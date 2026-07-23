import SwiftUI
import VoxglassCore

struct WatchSearchView: View {
    @EnvironmentObject var services: WatchAppServices
    @State private var searchText = ""
    @State private var searchScope: WatchSearchScope = .myBooks

    enum WatchSearchScope: String, CaseIterable {
        case myBooks = "My Books"
        case librivox = "LibriVox"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if searchText.isEmpty {
                    VStack(spacing: 8) {
                        Text("Search")
                            .font(.headline)
                        Text("Type to search My Books or LibriVox")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    if services.catalogStore.isSearching {
                        ProgressView("Searching...")
                    } else if let error = services.catalogStore.catalogError {
                        VStack(spacing: 8) {
                            Text("Search Error")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    } else {
                        List(services.catalogStore.results, id: \.identifier) { result in
                            NavigationLink {
                                WatchRemoteBookDetailView(identifier: result.identifier, title: result.title)
                                    .accessibilityIdentifier(WatchAccessibilityID.bookDetail)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                    if !result.creators.isEmpty {
                                        Text(result.creators.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search books")
            .onChange(of: searchText) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task {
                    if searchScope == .librivox {
                        await services.catalogStore.searchLibriVox(newValue)
                    }
                }
            }
            .accessibilityIdentifier(WatchAccessibilityID.rootSearch)
        }
    }
}

struct WatchRemoteBookDetailView: View {
    let identifier: String
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .lineLimit(3)

                Text("This book needs to be added to your library before streaming.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    // Add to My Books
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Add to My Books")
                    }
                }
                .accessibilityIdentifier(WatchAccessibilityID.bookAdd)

                Button {
                    // Stream
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Stream")
                    }
                }
                .accessibilityIdentifier(WatchAccessibilityID.bookStream)
            }
            .padding()
        }
    }
}
