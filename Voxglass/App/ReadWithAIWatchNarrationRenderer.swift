// Text narration is played on iPhone only. Keep the retired symbol unavailable
// so an accidental future call cannot restore speech rendering for Watch.
@available(*, unavailable, message: "Read by AI books cannot be downloaded to Apple Watch.")
enum ReadWithAIWatchNarrationRenderer {}
