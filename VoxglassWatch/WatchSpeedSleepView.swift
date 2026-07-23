import SwiftUI

struct WatchSpeedSleepView: View {
    @State private var playbackRate: Double = 1.0
    @State private var sleepTimer: WatchSleepTimerMode = .off

    enum WatchSleepTimerMode: String, CaseIterable {
        case off = "Off"
        case fiveMin = "5 min"
        case fifteenMin = "15 min"
        case thirtyMin = "30 min"
        case endOfChapter = "End of Chapter"
    }

    var body: some View {
        List {
            Section("Speed") {
                VStack(spacing: 4) {
                    Text("\(playbackRate, specifier: "%.1f")x")
                        .font(.headline)
                    Slider(value: $playbackRate, in: 0.5...3.5, step: 0.1)
                }
            }

            Section("Sleep Timer") {
                Picker("Timer", selection: $sleepTimer) {
                    ForEach(WatchSleepTimerMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue)
                    }
                }
            }
        }
        .accessibilityIdentifier(WatchAccessibilityID.playbackOptions)
    }
}
