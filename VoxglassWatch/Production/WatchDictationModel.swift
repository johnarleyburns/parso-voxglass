import Foundation
import Observation
import VoxglassCore
import WatchKit

/// Dictation flow (mockups 07–08): category → dictated text → confirm → a `.addNote`
/// review event. Uses `WKExtension`'s text input controller in `.dictation` mode.
@MainActor
@Observable
public final class WatchDictationModel {

    public enum Stage: Sendable {
        case category
        case dictating
        case result
    }

    public var stage: Stage = .category
    public var selectedTag: ReviewTag?
    public var dictatedText: String?

    private let environment: ProductionWatchEnvironment
    private let onSave: (String, ReviewTag?) async -> Void
    private let isSmoke: Bool

    public init(
        environment: ProductionWatchEnvironment,
        isSmoke: Bool = ProductionWatchSmoke.isEnabled,
        onSave: @escaping (String, ReviewTag?) async -> Void
    ) {
        self.environment = environment
        self.isSmoke = isSmoke
        self.onSave = onSave
    }

    public func choose(_ tag: ReviewTag) {
        selectedTag = tag
        stage = .dictating
        beginDictation()
    }

    public func beginDictation() {
        if isSmoke {
            dictatedText = "Pronounce Poirot more softly; second syllable too sharp."
            stage = .result
            return
        }
        stage = .dictating
        let controller = WKInterfaceController()
        controller.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .plain
        ) { [weak self] results in
            Task { @MainActor in
                guard let text = results?.first as? String else { return }
                self?.dictatedText = text
                self?.stage = .result
            }
        }
    }

    public func redictate() {
        dictatedText = nil
        beginDictation()
    }

    public func save() async {
        guard let text = dictatedText else { return }
        await onSave(text, selectedTag)
    }
}
