import Foundation
import SwiftUI
import AVFoundation
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
    @Published var playing: WatchPlayingSession?
    @Published var error: String?
    private var player: AVPlayer?

    var isConnected: Bool { session.isReachable }
    var visibleBooks: [WatchBookDTO] { isConnected ? books : books.filter { downloaded.contains($0.id) } }

    func bootstrap() { session.refresh(); books = session.snapshot?.books ?? []; downloaded = Set(UserDefaults.standard.stringArray(forKey: "watch.downloaded")?.map(WatchBookID.init) ?? []) }
    func download(_ book: WatchBookDTO) { downloaded.insert(book.id); UserDefaults.standard.set(downloaded.map(\.rawValue), forKey: "watch.downloaded") }
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
}
