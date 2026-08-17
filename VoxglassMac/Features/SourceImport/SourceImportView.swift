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

                    if model.importWarningCount > 0 {
                        Label("\(model.importWarningCount) import warning\(model.importWarningCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("import.warningCount")
                    }

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
        .sheet(isPresented: Binding(
            get: { model.reimportSummary != nil },
            set: { if !$0 { model.dismissReimportSummary() } }
        )) {
            reimportSheet
        }
    }

    /// Re-import reconciliation sheet (§18.1.4, mockup `19`). Orphan
    /// retirement stays non-destructive: the audio assets remain in the store;
    /// only the project rows are dropped (§22.6).
    private var reimportSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import completed")
                .font(.title)
            if let summary = model.reimportSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reusing \(summary.reused) paragraphs")
                    Text("\(summary.added) new")
                        .accessibilityIdentifier("import.reimport.added")
                    Text("\(summary.retired) no longer in source (\(summary.retiredWithRecordings) have recordings)")
                        .accessibilityIdentifier("import.reimport.retired")
                    if summary.drifted > 0 {
                        Text("\(summary.drifted) changed text")
                            .accessibilityIdentifier("import.reimport.drifted")
                    }
                }
                .font(.body)

                if summary.retiredWithRecordings > 0 {
                    Text("The retired paragraphs with recordings are kept in a separate chapter so no take is lost. You can review them there before discarding.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Keep Orphans") {
                    model.dismissReimportSummary()
                }
                Button("Discard Orphans") {
                    Task { await model.discardOrphans(env) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.reimportSummary?.retired == 0)
                .accessibilityIdentifier("import.reimport.discard")
            }
        }
        .padding(24)
        .frame(width: 480)
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
