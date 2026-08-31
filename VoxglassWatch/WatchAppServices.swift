import Foundation
import SwiftUI
import AVFoundation
import Combine
import VoxglassWatchProtocol
import VoxglassWatchCore

struct WatchPlayingSession: Equatable {
    var book: WatchBookDTO
    var chapterIndex: Int
    var position: TimeInterval = 0
    var isPlaying = false
}

@MainActor
final class WatchAppServices: ObservableObject {
    static let shared = WatchAppServices()
    let session = WatchSessionAdapter.shared
    @Published private(set) var books: [WatchBookDTO] = []
    @Published private(set) var downloaded = Set<WatchBookID>()
    @Published private(set) var downloading = Set<WatchBookID>()
    @Published var playing: WatchPlayingSession?
    @Published var error: String?
    private var player: AVPlayer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        session.$snapshot
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in self?.books = snapshot.books }
            .store(in: &cancellables)
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        session.$requestedDownloadBookID
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] bookID in
                guard let self, let book = self.books.first(where: { $0.id == bookID }) else { return }
                self.startDownload(book, notifyPhone: false)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .watchRemoveDownloadedBook)
            .compactMap { $0.object as? String }
            .receive(on: RunLoop.main)
            .sink { [weak self] rawID in
                guard let self, let book = self.books.first(where: { $0.id.rawValue == rawID }) else { return }
                self.remove(book)
            }
            .store(in: &cancellables)
    }

    var isConnected: Bool { session.isReachable }
    var visibleBooks: [WatchBookDTO] { isConnected ? books : books.filter { downloaded.contains($0.id) } }

    func bootstrap() {
        downloaded = Set(UserDefaults.standard.stringArray(forKey: "watch.downloaded")?.map(WatchBookID.init) ?? [])
        books = session.snapshot?.books ?? []
        session.refresh()
    }

    func download(_ book: WatchBookDTO) {
        startDownload(book, notifyPhone: true)
    }

    private func startDownload(_ book: WatchBookDTO, notifyPhone: Bool) {
        guard !downloading.contains(book.id) else { return }
        if notifyPhone {
            session.requestDownload(for: book)
        }
        downloading.insert(book.id)
        Task { await downloadApprovedChapters(for: book) }
    }
    func remove(_ book: WatchBookDTO) { downloaded.remove(book.id); UserDefaults.standard.set(downloaded.map(\.rawValue), forKey: "watch.downloaded") }
    func play(_ book: WatchBookDTO, chapterIndex: Int = 0) {
        guard !book.chapters.isEmpty else { error = "No playable chapters."; return }
        let index = min(max(0, chapterIndex), book.chapters.count - 1)
        playing = WatchPlayingSession(book: book, chapterIndex: index, isPlaying: true)
        if let url = book.chapters[index].approvedStreamURL { player = AVPlayer(url: url); player?.play() }
    }
    func togglePlayPause() { guard var playing else { return }; playing.isPlaying.toggle(); self.playing = playing; playing.isPlaying ? player?.play() : player?.pause() }
    func nextChapter() { move(by: 1) }
    func previousChapter() { move(by: -1) }
    private func move(by amount: Int) { guard let current = playing else { return }; let index = current.chapterIndex + amount; guard current.book.chapters.indices.contains(index) else { return }; play(current.book, chapterIndex: index) }

    private func downloadApprovedChapters(for book: WatchBookDTO) async {
        let urls = book.chapters.compactMap(\.approvedStreamURL)
        guard urls.count == book.chapters.count, !urls.isEmpty else {
            downloading.remove(book.id)
            error = "Waiting for the iPhone to transfer this book."
            return
        }
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("DownloadedBooks/\(book.id.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var bytes: Int64 = 0
            for (chapter, url) in zip(book.chapters, urls) {
                let (temporary, _) = try await URLSession.shared.download(from: url)
                let destination = root.appendingPathComponent(chapter.durableFilename)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                bytes += Int64((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0)
            }
            downloaded.insert(book.id)
            UserDefaults.standard.set(downloaded.map(\.rawValue), forKey: "watch.downloaded")
            session.reportDownload(book: book, bytes: bytes, complete: true)
        } catch {
            self.error = "Download failed: \(error.localizedDescription)"
            session.reportDownload(book: book, bytes: 0, complete: false)
        }
        downloading.remove(book.id)
    }
}
