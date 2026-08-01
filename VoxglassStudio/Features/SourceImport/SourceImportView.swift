import SwiftUI
import VoxglassCore
import UniformTypeIdentifiers

struct SourceImportView: View {
    @Environment(StudioEnvironment.self) private var env
    @State private var model = SourceImportModel()
    @State private var showFilePicker = true

    var body: some View {
        VStack(spacing: 16) {
            Text("Import Source Text")
                .font(.title)

            if model.isLoading {
                ProgressView("Importing…")
            } else if let document = model.extractedDocument {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Detected: \(model.sourceDescription)")
                        .font(.headline)

                    Text("\(document.sections.count) chapters")
                        .accessibilityIdentifier("import.chapterCount")

                    ScrollView {
                        ForEach(Array(document.sections.enumerated()), id: \.offset) { index, section in
                            HStack {
                                Text("Chapter \(index + 1)")
                                    .fontWeight(.medium)
                                Text(section.heading ?? "Untitled")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(section.blocks.count) ¶")
                                    .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxHeight: 300)

                    HStack {
                        Button("Cancel") {
                            env.navigate(to: .library)
                        }
                        Button("Accept Structure") {
                            Task {
                                await model.applyToProject(env)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("import.acceptStructure")
                    }
                }
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Text("Import failed")
                        .font(.headline)
                    Text(error)
                        .foregroundColor(.red)
                    Button("Try Again") {
                        showFilePicker = true
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("Source Import")
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: sourceTypes) { result in
            if case .success(let url) = result {
                Task {
                    await model.importSource(from: url, into: env)
                }
            }
        }
    }

    private var sourceTypes: [UTType] {
        [
            .plainText,
            UTType(filenameExtension: "epub") ?? .data,
            UTType(filenameExtension: "docx") ?? .data,
            UTType(filenameExtension: "md") ?? .data,
        ]
    }
}
