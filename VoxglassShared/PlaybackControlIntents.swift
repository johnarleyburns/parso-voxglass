import AppIntents

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Resumes the audiobook you were last listening to in Voxglass.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await PlaybackCommandRouter.perform(.resume)
        return .result(dialog: "Resuming Voxglass")
    }
}

struct TogglePlaybackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause Voxglass"
    static let description = IntentDescription("Play or pause the current audiobook in Voxglass.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await PlaybackCommandRouter.perform(.togglePlayPause)
        return .result()
    }
}

struct SkipBackwardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Back in Voxglass"
    static let description = IntentDescription("Skip backward in the current audiobook.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await PlaybackCommandRouter.perform(.skipBackward)
        return .result()
    }
}

struct SkipForwardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Forward in Voxglass"
    static let description = IntentDescription("Skip forward in the current audiobook.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await PlaybackCommandRouter.perform(.skipForward)
        return .result()
    }
}

struct CycleSleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cycle Voxglass Sleep Timer"
    static let description = IntentDescription("Change the current audiobook sleep timer.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        try await PlaybackCommandRouter.perform(.cycleSleepTimer)
        return .result()
    }
}
