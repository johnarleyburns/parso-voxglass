import SwiftUI
import VoxglassCore

/// Spec §7.7 recovery sheet: offered when `Autosave/session.json` exists at
/// package-open time. Keep as take / Discard.
struct AutosaveRecoverySheet: View {
    let model: AutosaveRecoveryModel
    var onFinish: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.orange)
            Text("Recovered Recording")
                .font(.title2.bold())
            if let session = model.session {
                Text("Voxglass recovered a recording of \(model.paragraphLabel) (\(String(format: "%.1f", model.duration)) s) from a previous session.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recovery.message")
            }
            if let error = model.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Discard") {
                    Task {
                        await model.discard()
                        onFinish()
                    }
                }
                .accessibilityIdentifier("recovery.discard")
                .disabled(model.isProcessing)

                Button("Keep as take") {
                    Task {
                        await model.keepAsTake()
                        if model.didFinish || model.error != nil { onFinish() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("recovery.keep")
                .disabled(model.isProcessing || !model.canRecover)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
