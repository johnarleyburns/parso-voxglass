import SwiftUI

struct StudioCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Audiobook Project") {
                NotificationCenter.default.post(name: .studioNewProject, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open Project…") {
                NotificationCenter.default.post(name: .studioOpenProject, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Import Source…") {
                NotificationCenter.default.post(name: .studioImportSource, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Record") {
                NotificationCenter.default.post(name: .studioRecord, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command])
        }

        CommandGroup(after: .textEditing) {
            Button("Next Paragraph") {
                NotificationCenter.default.post(name: .studioNextParagraph, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])

            Button("Previous Paragraph") {
                NotificationCenter.default.post(name: .studioPreviousParagraph, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
        }

        CommandMenu("Project") {
            Button("Start Review Queue") {
                NotificationCenter.default.post(name: .studioReviewQueue, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Export…") {
                NotificationCenter.default.post(name: .studioExport, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command])

            Divider()

            Button("Verify Project") {
                NotificationCenter.default.post(name: .studioVerifyProject, object: nil)
            }

            Button("Rebuild Caches") {
                NotificationCenter.default.post(name: .studioRebuildCaches, object: nil)
            }
        }
    }
}

extension Notification.Name {
    static let studioNewProject = Notification.Name("studio.newProject")
    static let studioOpenProject = Notification.Name("studio.openProject")
    static let studioImportSource = Notification.Name("studio.importSource")
    static let studioRecord = Notification.Name("studio.record")
    static let studioNextParagraph = Notification.Name("studio.nextParagraph")
    static let studioPreviousParagraph = Notification.Name("studio.previousParagraph")
    static let studioReviewQueue = Notification.Name("studio.reviewQueue")
    static let studioExport = Notification.Name("studio.export")
    static let studioVerifyProject = Notification.Name("studio.verifyProject")
    static let studioRebuildCaches = Notification.Name("studio.rebuildCaches")
    static let studioRecordParagraphAdvance = Notification.Name("studio.recordParagraphAdvance")
}
