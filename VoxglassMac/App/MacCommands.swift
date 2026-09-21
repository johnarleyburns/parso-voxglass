import AppKit
import SwiftUI

enum MacCommandAction: Equatable {
    case destination(MacDestination)
    case search
    case record
    case acceptAndNext
    case retry
    case nextParagraph
    case previousParagraph
    case toggleInspector
    case showNowPlaying
}

struct MacCommandEvent: Identifiable {
    let id: Int
    let action: MacCommandAction
}

@MainActor
final class MacCommandRouter: ObservableObject {
    var handler: ((MacCommandAction) -> Void)?
    @Published private(set) var latestEvent: MacCommandEvent?
    private var nextEventID = 0

    func send(_ action: MacCommandAction) {
        nextEventID += 1
        latestEvent = MacCommandEvent(id: nextEventID, action: action)
        handler?(action)
    }
}

struct VoxglassMacCommands: Commands {
    @ObservedObject var router: MacCommandRouter
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("File") {
            Button("New Narration") { router.send(.destination(.narration)) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Project…") { router.send(.destination(.narration)) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandMenu("View") {
            Button("Listen") { router.send(.destination(.listen)) }
                .keyboardShortcut("1", modifiers: .command)
            Button("My Books") { router.send(.destination(.books)) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Discover") { router.send(.destination(.discover)) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Narration") { router.send(.destination(.narration)) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Search") { router.send(.search) }
                .keyboardShortcut("f", modifiers: .command)
            Button("Toggle Inspector") { router.send(.toggleInspector) }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
        CommandGroup(after: .textEditing) {
            Button("Add Note to Selected Paragraph") { router.send(.toggleInspector) }
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { router.send(.showNowPlaying) }
                .keyboardShortcut(.space, modifiers: [])
        }
        CommandMenu("Narration") {
            Button("Record / Stop") { router.send(.record) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Accept Take and Next") { router.send(.acceptAndNext) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Retry Take") { router.send(.retry) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Previous Paragraph") { router.send(.previousParagraph) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Next Paragraph") { router.send(.nextParagraph) }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Bring All to Front") { NSApp.activate(ignoringOtherApps: true) }
        }
        CommandGroup(replacing: .help) {
            Button("Voxglass Help") { NSWorkspace.shared.open(URL(string: "https://github.com/johnarleyburns/parso-voxglass")!) }
            Button("Keyboard Shortcuts") { router.send(.toggleInspector) }
        }
    }
}
