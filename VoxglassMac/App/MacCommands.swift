import AppKit
import SwiftUI

enum MacCommandAction: Equatable {
    case destination(MacDestination)
    case newNarration
    case search
    case openProject
    case importBook
    case importAudio
    case record
    case acceptAndNext
    case retry
    case nextParagraph
    case previousParagraph
    case previousChapter
    case nextChapter
    case addBookmark
    case addNote
    case openAudioSetup
    case openReviewExport
    case toggleInspector
    case showNowPlaying
    case stopPlayback
    case showKeyboardShortcuts
    case showRecordingTroubleshooting
    case sendDiagnostics
}

struct MacCommandEvent: Identifiable {
    let id: Int
    let action: MacCommandAction
}

struct MacCommandContext: Equatable {
    var destination: MacDestination = .listen
    var isTextEditorFocused = false
    var hasSelectedParagraph = false
    var hasSelectedTake = false
    var hasPlaybackSession = false

    func canPerform(_ action: MacCommandAction) -> Bool {
        switch action {
        case .destination, .newNarration, .toggleInspector, .showKeyboardShortcuts,
             .openProject, .importBook, .importAudio, .showRecordingTroubleshooting,
             .sendDiagnostics:
            !isTextEditorFocused
        case .search:
            destination != .narration && !isTextEditorFocused
        case .openAudioSetup, .openReviewExport, .addNote:
            destination == .narration && hasSelectedParagraph && !isTextEditorFocused
        case .record, .nextParagraph, .previousParagraph:
            destination == .narration && hasSelectedParagraph && !isTextEditorFocused
        case .acceptAndNext, .retry:
            destination == .narration && hasSelectedTake && !isTextEditorFocused
        case .previousChapter, .nextChapter, .addBookmark, .showNowPlaying, .stopPlayback:
            hasPlaybackSession
        }
    }
}

@MainActor
final class MacCommandRouter: ObservableObject {
    var handler: ((MacCommandAction) -> Void)?
    @Published private(set) var latestEvent: MacCommandEvent?
    @Published private(set) var context = MacCommandContext()
    private var nextEventID = 0

    func setDestination(_ destination: MacDestination) {
        context.destination = destination
        if destination != .narration {
            context.hasSelectedParagraph = false
            context.hasSelectedTake = false
        }
    }

    func setTextEditorFocused(_ focused: Bool) {
        context.isTextEditorFocused = focused
    }

    func setWorkspaceSelection(hasParagraph: Bool, hasTake: Bool) {
        context.hasSelectedParagraph = hasParagraph
        context.hasSelectedTake = hasTake
    }

    func setHasPlaybackSession(_ hasSession: Bool) {
        context.hasPlaybackSession = hasSession
    }

    func canPerform(_ action: MacCommandAction) -> Bool {
        context.canPerform(action)
    }

    func send(_ action: MacCommandAction) {
        guard canPerform(action) else { return }
        nextEventID += 1
        latestEvent = MacCommandEvent(id: nextEventID, action: action)
        handler?(action)
    }
}

private struct MacCommandRouterFocusedValueKey: FocusedValueKey {
    typealias Value = MacCommandRouter
}

extension FocusedValues {
    var voxglassMacCommandRouter: MacCommandRouter? {
        get { self[MacCommandRouterFocusedValueKey.self] }
        set { self[MacCommandRouterFocusedValueKey.self] = newValue }
    }
}

struct VoxglassMacCommands: Commands {
    @FocusedValue(\.voxglassMacCommandRouter) private var router
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("File") {
            Button("New Narration") { send(.newNarration) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Project…") { send(.openProject) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Import Book…") { send(.importBook) }
            Button("Import Audio…") { send(.importAudio) }
            Divider()
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandMenu("View") {
            Button("Listen") { send(.destination(.listen)) }
                .keyboardShortcut("1", modifiers: .command)
            Button("My Books") { send(.destination(.books)) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Discover") { send(.destination(.discover)) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Narration") { send(.destination(.narration)) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Search") { send(.search) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!canPerform(.search))
            Button("Toggle Inspector") { send(.toggleInspector) }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { send(.showNowPlaying) }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!canPerform(.showNowPlaying))
            Button("Stop") { send(.stopPlayback) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!canPerform(.stopPlayback))
            Divider()
            Button("Previous Chapter") { send(.previousChapter) }
                .disabled(!canPerform(.previousChapter))
            Button("Next Chapter") { send(.nextChapter) }
                .disabled(!canPerform(.nextChapter))
            Button("Add Bookmark") { send(.addBookmark) }
                .disabled(!canPerform(.addBookmark))
        }
        CommandMenu("Narration") {
            Button("Record / Stop") { send(.record) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canPerform(.record))
            Button("Accept Take and Next") { send(.acceptAndNext) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canPerform(.acceptAndNext))
            Button("Retry Take") { send(.retry) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canPerform(.retry))
            Divider()
            Button("Previous Paragraph") { send(.previousParagraph) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!canPerform(.previousParagraph))
            Button("Next Paragraph") { send(.nextParagraph) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!canPerform(.nextParagraph))
            Divider()
            Button("Add Note to Selected Paragraph") { send(.addNote) }
                .disabled(!canPerform(.addNote))
            Button("Open Audio Setup…") { send(.openAudioSetup) }
                .disabled(!canPerform(.openAudioSetup))
            Button("Open Review & Export…") { send(.openReviewExport) }
                .disabled(!canPerform(.openReviewExport))
        }
        CommandGroup(after: .windowArrangement) {
            Button("Bring All to Front") { NSApp.activate(ignoringOtherApps: true) }
        }
        CommandGroup(replacing: .help) {
            Button("Voxglass Help") { NSWorkspace.shared.open(URL(string: "https://github.com/johnarleyburns/parso-voxglass")!) }
            Button("Keyboard Shortcuts") { send(.showKeyboardShortcuts) }
            Button("Recording Troubleshooting") { send(.showRecordingTroubleshooting) }
            Button("Send Diagnostics…") { send(.sendDiagnostics) }
        }
    }

    private func send(_ action: MacCommandAction) {
        router?.send(action)
    }

    private func canPerform(_ action: MacCommandAction) -> Bool {
        router?.canPerform(action) ?? false
    }
}
