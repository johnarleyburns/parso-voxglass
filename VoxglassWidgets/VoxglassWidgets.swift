import AppIntents
import Foundation
import SwiftUI
import WidgetKit
import VoxglassCore

private let widgetKind = "guru.parso.voxglass.continue"

struct WidgetSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot?
    let widgetsAreEnabled: Bool
}

struct WidgetSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetSnapshotEntry {
        WidgetSnapshotEntry(date: .now, snapshot: nil, widgetsAreEnabled: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetSnapshotEntry) -> Void) {
        completion(WidgetSnapshotEntry(date: .now, snapshot: WidgetSnapshotStore.read(), widgetsAreEnabled: WidgetSnapshotStore.isEnabled))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetSnapshotEntry>) -> Void) {
        let entry = WidgetSnapshotEntry(date: .now, snapshot: WidgetSnapshotStore.read(), widgetsAreEnabled: WidgetSnapshotStore.isEnabled)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(60))))
    }
}

struct VoxglassContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: WidgetSnapshotProvider()) { entry in
            VoxglassWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue Voxglass")
        .description("Resume the audiobook you were last listening to.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])
    }
}

struct VoxglassWidgetView: View {
    let entry: WidgetSnapshotEntry

    var body: some View {
        if !entry.widgetsAreEnabled {
            VStack(spacing: 6) {
                Image(systemName: "rectangle.3.group.slash")
                Text("Widgets are off in Voxglass settings").font(.caption).multilineTextAlignment(.center)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else if let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.title).font(.headline).lineLimit(2)
                Text(snapshot.chapterTitle).font(.caption).lineLimit(1)
                ProgressView(value: snapshot.fraction)
                Button(intent: ResumeListeningIntent()) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "headphones")
                Text("Nothing to resume").font(.caption)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Voxglass"
    static let description = IntentDescription("Resume the last audiobook in Voxglass.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        WidgetPlaybackCommandStore.requestResume()
        return .result(dialog: "Resuming Voxglass")
    }
}

struct ResumeVoxglassControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.parso.voxglass.resume") {
            ControlWidgetButton("Resume Voxglass", action: ResumeListeningIntent()) { _ in
                Label("Resume", systemImage: "play.fill")
            }
        }
        .displayName("Resume Voxglass")
        .description("Resume the last audiobook in Voxglass.")
    }
}

enum WidgetSnapshotStore {
    static var isEnabled: Bool {
        guard let defaults = UserDefaults(suiteName: "group.guru.parso.voxglass") else { return true }
        guard defaults.object(forKey: "settings.widgetSnapshot") != nil else { return true }
        return defaults.bool(forKey: "settings.widgetSnapshot")
    }

    static func read() -> NowPlayingSnapshot? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.guru.parso.voxglass") else { return nil }
        let url = container.appendingPathComponent("now-playing.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }
}

@main
struct VoxglassWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoxglassContinueWidget()
        ResumeVoxglassControl()
    }
}
