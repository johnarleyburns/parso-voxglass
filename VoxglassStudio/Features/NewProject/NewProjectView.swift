import SwiftUI
import VoxglassCore

struct NewProjectView: View {
    @Environment(StudioEnvironment.self) private var env
    @State private var model = NewProjectModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("New Audiobook Project")
                .font(.title)

            Form {
                Section("Metadata") {
                    TextField("Title", text: $model.title)
                        .accessibilityIdentifier("wizard.title")
                    TextField("Author", text: $model.author)
                        .accessibilityIdentifier("wizard.author")
                    TextField("Narrator", text: $model.narrator)
                        .accessibilityIdentifier("wizard.narrator")
                    TextField("Language", text: $model.language)
                }

                Section("Purpose") {
                    Picker("Purpose", selection: $model.purpose) {
                        ForEach(ProjectPurpose.allCases, id: \.self) { purpose in
                            Text(purpose.displayName).tag(purpose)
                                .accessibilityIdentifier("wizard.purpose.\(purpose.rawValue)")
                        }
                    }
                }

                Section("Destination") {
                    Picker("Primary Destination", selection: $model.destination) {
                        ForEach(DestinationID.allCases, id: \.self) { dest in
                            Text(dest.rawValue).tag(dest)
                        }
                    }
                    .accessibilityIdentifier("wizard.destination")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    env.navigate(to: .library)
                }
                .accessibilityIdentifier("wizard.cancel")

                Button("Continue to Import") {
                    Task {
                        await model.createProject(using: env.library, at: Self.defaultProjectDirectory(title: model.title))
                        guard let project = model.createdProject else {
                            return
                        }
                        env.setProject(project)
                        env.push(to: .sourceImport)
                    }
                }
                .disabled(!model.canProceed)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wizard.continueToImport")
            }
            .padding(.bottom)
        }
        .frame(minWidth: 450, minHeight: 350)
        .alert("Project Creation Failed", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.error ?? "")
        }
    }

    private static func defaultProjectDirectory(title: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Voxglass Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safeTitle = title.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .replacingOccurrences(of: " ", with: "-")
        return base.appendingPathComponent("\(safeTitle).voxproject", isDirectory: true)
    }
}

extension ProjectPurpose {
    var displayName: String {
        switch self {
        case .publicDomainCommunity: "Public Domain / Community"
        case .personal: "Personal"
        case .commercial: "Commercial"
        }
    }
}
