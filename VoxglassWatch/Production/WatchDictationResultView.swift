import SwiftUI
import VoxglassCore

/// Dictation result (mockup 08): confirm the transcribed note before saving it as a
/// review event.
struct WatchDictationResultView: View {
    private let model: WatchDictationModel
    private let onDone: () -> Void

    init(model: WatchDictationModel, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let tag = model.selectedTag {
                    Text(tagLabel(tag))
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.3), in: Capsule())
                }

                Text(model.dictatedText ?? "")
                    .font(.footnote)
                    .lineSpacing(2)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    Button {
                        model.redictate()
                    } label: {
                        Label("Redictate", systemImage: "mic.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.dictationRedictate)
                    .contentShape(Rectangle())

                    Button {
                        Task {
                            await model.save()
                            onDone()
                        }
                    } label: {
                        Label("Save & Continue", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(ProductionWatchAccessibility.dictationSave)
                    .contentShape(Rectangle())
                }
            }
            .padding()
        }
        .navigationTitle("Review Note")
    }

    private func tagLabel(_ tag: ReviewTag) -> String {
        switch tag {
        case .misread: "Misread"
        case .pronunciation: "Pronunciation"
        case .pacing: "Pacing"
        case .noise: "Noise"
        case .performance: "Performance"
        case .edit: "Edit"
        }
    }
}
