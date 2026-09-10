import SwiftUI
import VoxglassWatchProtocol

struct WatchLibraryView: View {
    @EnvironmentObject private var services: WatchAppServices
    // The connection indicator used to be a permanent `.safeAreaInset` —
    // always reserving space at the top of the list, whether the connection
    // state had just changed or not. It's meant to be a brief toast: shown
    // on appear and whenever the connection state actually changes, then
    // auto-dismissed a couple seconds later.
    @State private var showConnectionToast = false
    @State private var toastDismissWork: DispatchWorkItem?

    var body: some View {
        List {
            if services.visibleBooks.isEmpty {
                VStack(spacing: 8) { Image(systemName: "arrow.down.circle").font(.title2); Text("No downloaded books").font(.headline); Text("In My Books on iPhone, choose Download to Apple Watch.").font(.caption).multilineTextAlignment(.center) }
                    .accessibilityIdentifier("watch.empty.downloads")
            } else {
                ForEach(services.visibleBooks, id: \.id) { book in
                    NavigationLink { WatchBookDetailView(book: book) } label: { WatchBookRow(book: book) }.accessibilityIdentifier("watch.book.\(book.id.rawValue)")
                }
            }
            aboutRow
        }
        .accessibilityIdentifier("watch.library")
        .navigationTitle("My Books")
        .overlay(alignment: .top) {
            if showConnectionToast {
                connectionToast
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear { presentConnectionToast() }
        .onChange(of: services.isConnected) { _, _ in presentConnectionToast() }
    }

    private var aboutRow: some View {
        NavigationLink { WatchAboutView() } label: { Text("About") }
            .accessibilityIdentifier("watch.about.row")
    }

    private var connectionToast: some View {
        HStack {
            Circle().fill(services.isConnected ? .green : .orange).frame(width: 7, height: 7)
            Text(services.isConnected ? "iPhone connected" : "On This Watch").font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier("watch.connection")
    }

    private func presentConnectionToast() {
        toastDismissWork?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { showConnectionToast = true }
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.2)) { showConnectionToast = false } }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

private struct WatchBookRow: View {
    let book: WatchBookDTO
    @EnvironmentObject private var services: WatchAppServices
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if services.downloading.contains(book.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: services.downloaded.contains(book.id) ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(services.downloaded.contains(book.id) ? .green : .secondary)
            }
        }
    }
}
