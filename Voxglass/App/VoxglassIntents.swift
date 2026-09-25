import AppIntents
import Combine
import Foundation
import VoxglassCore

// Siri / Shortcuts / CarPlay voice for Voxglass — the P0 slice of
// docs/INTENTS_LIVE_ACTIVITY_SIRI_PLAN.md that matters in the car:
//
//   "Hey Siri, resume Voxglass"
//   "Hey Siri, play The Odyssey in Voxglass"
//
// Before iOS 27 an audio app may not show CPSearchTemplate in CarPlay at all
// (Apple CarPlay Developer Guide, Templates table), so on the iOS 18 phone in
// the car, voice is the only way to find a book by name while driving.
//
// Design rules carried over from the plan:
// - Playback intents conform to `AudioPlaybackIntent` and set
//   `openAppWhenRun = false`. An intent that asks to foreground the app is
//   refused while CarPlay is active ("I can't do that while you're driving").
// - Every intent goes through the same `AppServices.shared.playbackCoordinator`
//   the UI and CarPlay use: no second playback path, no second position writer.
// - Every result carries a spoken dialog, so it works without a screen.

// MARK: - Book entity

struct BookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Audiobook"
    static let defaultQuery = BookEntityQuery()

    let id: UUID
    let title: String
    let author: String

    var displayRepresentation: DisplayRepresentation {
        if author.isEmpty {
            return DisplayRepresentation(title: "\(title)")
        }
        return DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
    }

    init(id: UUID, title: String, author: String) {
        self.id = id
        self.title = title
        self.author = author
    }

    init(_ book: BookWithChapters) {
        self.init(id: book.book.id, title: book.book.title, author: book.book.authorLine)
    }
}

/// Backs Siri's book lookup with the same matcher CarPlay search uses
/// (`LibraryVoiceSearch`), plus a partial fallback because transcriptions
/// mangle author and narrator names.
struct BookEntityQuery: EntityStringQuery {
    func entities(for identifiers: [BookEntity.ID]) async throws -> [BookEntity] {
        await VoxglassIntentBridge.entities(for: identifiers)
    }

    func entities(matching string: String) async throws -> [BookEntity] {
        await VoxglassIntentBridge.entities(matching: string)
    }

    func suggestedEntities() async throws -> [BookEntity] {
        await VoxglassIntentBridge.suggestedEntities()
    }
}

// MARK: - Intents

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Resumes the audiobook you were last listening to in Voxglass.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = await VoxglassIntentBridge.prepare()
        let coordinator = services.playbackCoordinator

        // Cold launch from Siri: resolve "where you were" through the same
        // path launch restore uses (it never clobbers a loaded or playing
        // session, so this is safe to race with the bootstrap's own call).
        if coordinator.currentSession == nil {
            await coordinator.restorePresentedSession(from: services.libraryStore.books)
        }

        if let session = coordinator.currentSession {
            if session.isPlaying {
                return .result(dialog: "Already playing \(session.book.title)")
            }
            // A paused session is already loaded at the right spot; resume it
            // in place rather than reloading the book.
            coordinator.togglePlayPause()
            return .result(dialog: "Resuming \(session.book.title)")
        }

        guard let book = services.libraryStore.recentlyPlayed.first else {
            return .result(dialog: "There's nothing to resume in Voxglass yet.")
        }
        await coordinator.play(book)
        return .result(dialog: "Resuming \(book.book.title)")
    }
}

struct PlayBookIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Audiobook"
    static let description = IntentDescription("Plays an audiobook from your Voxglass library, from where you left off.")
    static let openAppWhenRun = false

    @Parameter(title: "Audiobook")
    var book: BookEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = await VoxglassIntentBridge.prepare()
        guard let target = services.libraryStore.book(withID: book.id) else {
            throw VoxglassIntentError("\(book.title) is no longer in your Voxglass library.")
        }
        await services.playbackCoordinator.play(target)
        return .result(dialog: "Playing \(target.book.title)")
    }
}

struct VoxglassIntentError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

// MARK: - App Shortcuts (Siri phrases; no setup needed by the listener)

struct VoxglassShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeListeningIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume my audiobook in \(.applicationName)",
                "Continue my book in \(.applicationName)"
            ],
            shortTitle: "Resume Listening",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Play \(\.$book) on \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
                "Play a book in \(.applicationName)"
            ],
            shortTitle: "Play Audiobook",
            systemImageName: "books.vertical"
        )
    }
}

// MARK: - Bridge into the running app

/// The only way intents reach app state. An intent can wake a cold, UI-less
/// app process (Siri in the car, phone locked), so every entry point first
/// makes sure the library is in memory.
@MainActor
enum VoxglassIntentBridge {
    /// How many books to offer Siri as spoken values for "Play <book> in
    /// Voxglass" phrases. Recently played first, then the rest of the library.
    static let suggestedLimit = 100

    private static var libraryObservation: AnyCancellable?

    /// Starts the normal, idempotent bootstrap without waiting on its network
    /// tail (the same bounded approach the CarPlay scene takes), but loads the
    /// library before returning so lookups never see an empty store.
    static func prepare() async -> AppServices {
        let services = AppServices.shared
        Task { @MainActor in await services.bootstrapOnce() }
        if services.libraryStore.books.isEmpty {
            await services.libraryStore.refresh()
        }
        return services
    }

    static func entities(for identifiers: [UUID]) async -> [BookEntity] {
        let library = await prepare().libraryStore
        return identifiers.compactMap { library.book(withID: $0).map { BookEntity($0) } }
    }

    static func entities(matching string: String) async -> [BookEntity] {
        let library = await prepare().libraryStore
        let ids = LibraryVoiceSearch.rank(
            query: string,
            candidates: library.books.map(candidate),
            allowPartial: true
        )
        return ids.prefix(10).compactMap { library.book(withID: $0).map { BookEntity($0) } }
    }

    static func suggestedEntities() async -> [BookEntity] {
        let library = await prepare().libraryStore
        var seen = Set<UUID>()
        return (library.recentlyPlayed + library.books)
            .filter { seen.insert($0.book.id).inserted }
            .prefix(suggestedLimit)
            .map { BookEntity($0) }
    }

    /// Keeps Siri's list of spoken book names current as the library changes.
    /// Called once from `AppServices.bootstrap()`.
    static func observeLibrary(_ library: LibraryStore) {
        VoxglassShortcuts.updateAppShortcutParameters()
        guard libraryObservation == nil else { return }
        libraryObservation = library.$books
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { _ in VoxglassShortcuts.updateAppShortcutParameters() }
    }

    private static func candidate(_ book: BookWithChapters) -> LibraryVoiceSearch.Candidate {
        LibraryVoiceSearch.Candidate(
            id: book.book.id,
            title: book.book.title,
            authorLine: book.book.authorLine,
            authors: book.book.authors,
            narrators: book.book.narrators
        )
    }
}
