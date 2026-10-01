import SwiftUI
import VoxglassCore

/// Book-language filter shared by Settings and Onboarding.
///
/// Shows chips for the largest LibriVox languages (plus the device language and
/// anything already selected), and an "All Languages" sheet that lists every
/// language in the collection with search and item counts. An empty selection
/// means every language.
struct LanguageFilterPicker: View {
    @Binding var selection: Set<String>
    @State private var showAll = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    private var chipLanguages: [LibriVoxLanguage] {
        var languages = LibriVoxLanguage.popular()
        let extra = LibriVoxLanguage.sortedByName()
            .filter { selection.contains($0.id) && !languages.contains($0) }
        languages.append(contentsOf: extra)
        return languages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(chipLanguages) { language in
                    LanguageChip(language: language, isSelected: selection.contains(language.id)) {
                        toggle(language.id)
                    }
                }
            }

            Button {
                showAll = true
            } label: {
                HStack(spacing: 6) {
                    Text("All Languages")
                    Text(verbatim: "(\(LibriVoxLanguage.all.count))")
                        .foregroundStyle(Palette.ink3)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .voxFont(.caption2, weight: .bold)
                        .foregroundStyle(Palette.ink3)
                }
                .voxFont(.caption, weight: .semibold)
                .foregroundStyle(Palette.brass)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("languages.showAll")
        }
        .sheet(isPresented: $showAll) {
            NavigationStack {
                AllLanguagesList(selection: $selection)
            }
            .presentationDragIndicator(.visible)
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

private struct LanguageChip: View {
    let language: LibriVoxLanguage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(language.displayName)
                    .minimumScaleFactor(0.8)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if isSelected {
                    Image(systemName: "checkmark")
                        .voxFont(.caption2, weight: .bold)
                }
            }
            .voxFont(.caption, weight: .semibold)
            .foregroundStyle(isSelected ? Color(hex: 0x221503) : Palette.ink2)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, 4)
            .background(
                isSelected ? Palette.brass : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Every LibriVox language, sorted by its name in the interface language.
private struct AllLanguagesList: View {
    @Binding var selection: Set<String>
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var languages: [LibriVoxLanguage] {
        LibriVoxLanguage.sortedByName().filter { LibriVoxLanguage.matches($0, search: search) }
    }

    var body: some View {
        List {
            Section {
                ForEach(languages) { language in
                    row(language)
                }
            } footer: {
                Text("Leave every language off to include books in all languages.")
            }
        }
        .searchable(text: $search, prompt: Text("Search Languages"))
        .navigationTitle("All Languages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear") { selection = [] }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("languages.clear")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func row(_ language: LibriVoxLanguage) -> some View {
        let isSelected = selection.contains(language.id)
        return Button {
            if isSelected {
                selection.remove(language.id)
            } else {
                selection.insert(language.id)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.displayName)
                        .foregroundStyle(Palette.ink)
                    Text("\(language.itemCount) books")
                        .voxFont(.caption)
                        .foregroundStyle(Palette.ink3)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.brass)
                        .voxFont(.body, weight: .semibold)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("languages.row.\(language.id)")
    }
}
