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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    cover(for: snapshot)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CONTINUE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(snapshot.title).font(.headline).lineLimit(2).widgetAccentable()
                        Text("\(snapshot.chapterTitle) · \(snapshot.minutesLeftInChapter) min left")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        ProgressView(value: snapshot.fraction)
                        transport(for: snapshot)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.title).font(.headline).lineLimit(2).widgetAccentable()
                    Text(snapshot.chapterTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgressView(value: snapshot.fraction)
                    if snapshot.isPlaying {
                        Button(intent: TogglePlaybackIntent()) { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(intent: ResumeListeningIntent()) { Label("Resume", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .containerBackground(for: .widget) {
                LinearGradient(colors: [color(snapshot.backgroundHex ?? 0x17191D), .black], startPoint: .top, endPoint: .bottom)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.orange).widgetAccentable()
                Text("Nothing playing yet").font(.caption)
                Link("Find a book", destination: URL(string: "voxglass://discover")!)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    @ViewBuilder
    private func cover(for snapshot: NowPlayingSnapshot) -> some View {
        if let url = CoverThumbnailStore.url(for: snapshot.bookID), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10).fill(color(snapshot.backgroundHex ?? 0x17191D)).frame(width: 56, height: 56)
                .overlay(Image(systemName: "waveform").foregroundStyle(color(snapshot.accentHex ?? 0xE3A44B)))
        }
    }

    private func transport(for snapshot: NowPlayingSnapshot) -> some View {
        HStack(spacing: 12) {
            Button(intent: SkipBackwardIntent()) { Image(systemName: "gobackward.15") }.accessibilityLabel("Skip back 15 seconds")
            if snapshot.isPlaying {
                Button(intent: TogglePlaybackIntent()) { Image(systemName: "pause.fill") }.accessibilityLabel("Pause")
            } else {
                Button(intent: ResumeListeningIntent()) { Image(systemName: "play.fill") }.accessibilityLabel("Resume")
            }
            Button(intent: SkipForwardIntent()) { Image(systemName: "goforward.30") }.accessibilityLabel("Skip forward 30 seconds")
        }
        .buttonStyle(.plain)
    }

    private func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
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

struct SleepTimerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.parso.voxglass.sleep") {
            ControlWidgetButton("Sleep Timer", action: CycleSleepTimerIntent()) { _ in
                Label("Sleep Timer", systemImage: "moon.zzz")
            }
        }
        .displayName("Sleep Timer")
        .description("Change the current audiobook sleep timer.")
    }
}

struct SkipBackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "guru.parso.voxglass.skipBack") {
            ControlWidgetButton("Skip Back", action: SkipBackwardIntent()) { _ in
                Label("Skip Back", systemImage: SkipSymbols.back(15))
            }
        }
        .displayName("Skip Back")
        .description("Skip back 15 seconds in Voxglass.")
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
        BookLiveActivity()
        ResumeVoxglassControl()
        SleepTimerControl()
        SkipBackControl()
    }
}
