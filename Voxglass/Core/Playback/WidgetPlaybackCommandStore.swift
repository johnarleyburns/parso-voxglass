import Foundation

/// Small app-group command handoff used by widget controls. The widget
/// extension cannot reach the app's playback coordinator directly, so it
/// records an intent for the running app to consume on its main actor.
public enum WidgetPlaybackCommandStore {
    private static let appGroup = "group.guru.parso.voxglass"
    private static let fileName = "widget-playback-command.json"

    public enum Command: String, Codable, Sendable {
        case resume
    }

    public static func requestResume() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let url = container.appendingPathComponent(fileName)
        guard let data = try? JSONEncoder().encode(Command.resume) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func consume() -> Command? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let url = container.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let command = try? JSONDecoder().decode(Command.self, from: data) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return command
    }
}
