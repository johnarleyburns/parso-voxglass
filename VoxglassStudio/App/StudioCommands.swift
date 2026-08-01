import SwiftUI

struct StudioCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Audiobook Project") {
                NotificationCenter.default.post(name: .studioNewProject, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Open Project...") {
                NotificationCenter.default.post(name: .studioOpenProject, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}

extension Notification.Name {
    static let studioNewProject = Notification.Name("studio.newProject")
    static let studioOpenProject = Notification.Name("studio.openProject")
}
