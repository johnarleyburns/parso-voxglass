import SwiftUI
import VoxglassCore

/// Dictation category (mockup 07): choose a note type, then dictate. Long-press on the
/// review player routes here too.
struct WatchDictationCategoryView: View {
    @Environment(ProductionWatchEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: WatchDictationModel?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ReviewTag.allCases, id: \.self) { tag in
                    Button {
                        model?.choose(tag)
                    } label: {
                        Text(tagLabel(tag))
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(tag == .pronunciation ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(tag == .pronunciation ? .white : .primary)
                    }
                    .accessibilityIdentifier(ProductionWatchAccessibility.dictationCategory(tag))
                    .contentShape(Rectangle())
                }
            }

            Button {
                model?.beginDictation()
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26))
                    .frame(width: 70, height: 70)
                    .background(Color.blue.opacity(0.2), in: Circle())
            }
            .accessibilityIdentifier(ProductionWatchAccessibility.dictate)
            .contentShape(Rectangle())
            .padding(.top, 12)

            Text("Tap to dictate a note")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("Note Type")
        .task {
            if model == nil {
                let environment = env
                model = WatchDictationModel(environment: environment) { [weak environment] text, tag in
                    await environment?.review?.addNote(text, tag: tag)
                }
            }
        }
        .sheet(isPresented: resultBinding) {
            if let model {
                WatchDictationResultView(model: model, onDone: {
                    dismiss()
                })
            }
        }
    }

    private var resultBinding: Binding<Bool> {
        Binding(
            get: { model?.stage == .result },
            set: { if !$0 { model?.stage = .category } }
        )
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
