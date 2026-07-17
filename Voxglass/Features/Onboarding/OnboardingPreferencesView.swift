import SwiftUI
import VoxglassCore

struct OnboardingPreferencesView: View {
    var initialSelection: Set<String>
    var finishAction: (Set<String>) -> Void
    var skipAction: () -> Void

    @State private var selectedCollectionIDs: Set<String>
    @AppStorage(AppPreferencesStore.Keys.selectedLanguages) private var selectedLanguagesRaw = "eng"

    init(
        initialSelection: Set<String>,
        finishAction: @escaping (Set<String>) -> Void,
        skipAction: @escaping () -> Void
    ) {
        self.initialSelection = initialSelection
        self.finishAction = finishAction
        self.skipAction = skipAction
        _selectedCollectionIDs = State(initialValue: initialSelection)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 142), spacing: 10)
    ]

    private let languageColumns = [
        GridItem(.adaptive(minimum: 104), spacing: 8)
    ]

    private var selectedLanguages: Set<String> {
        AppPreferencesStore.decodeLanguages(selectedLanguagesRaw)
    }

    var body: some View {
        ZStack {
            VoxglassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    languagesSection
                    tasteGrid
                    featuredCollections
                    footerActions
                }
                .padding(.horizontal, 22)
                .padding(.top, 28)
                .padding(.bottom, 34)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles")
                .scaledFont(size: 20)
                .foregroundStyle(Palette.brass)
                .frame(width: 44, height: 44)
                .glassSurface(cornerRadius: 14)

            Text("Choose a few interests")
                .scaledFont(size: 31, weight: .heavy)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Voxglass will start with popular LibriVox picks and refresh the shelf around your selections.")
                .scaledFont(size: 14)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Languages")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(Palette.ink2)

            LazyVGrid(columns: languageColumns, spacing: 8) {
                ForEach(LibriVoxLanguage.all) { language in
                    languageChip(language)
                }
            }
        }
    }

    private func languageChip(_ language: LibriVoxLanguage) -> some View {
        let isSelected = selectedLanguages.contains(language.id)
        return Button {
            toggleLanguage(language.id)
        } label: {
            HStack(spacing: 6) {
                Text(language.displayName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 10, weight: .bold)
                }
            }
            .scaledFont(size: 12.5, weight: .semibold)
            .foregroundStyle(isSelected ? Color(hex: 0x221503) : Palette.ink2)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(
                isSelected ? Palette.brass : Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggleLanguage(_ id: String) {
        var codes = selectedLanguages
        if codes.contains(id) {
            codes.remove(id)
        } else {
            codes.insert(id)
        }
        selectedLanguagesRaw = AppPreferencesStore.encodeLanguages(codes)
    }

    private var tasteGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(IACollectionStore.allSelectableCollections) { collection in
                CollectionSelectionChip(
                    collection: collection,
                    isSelected: selectedCollectionIDs.contains(collection.id)
                ) {
                    toggle(collection)
                }
            }
        }
    }

    private var featuredCollections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or browse our collections")
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(Palette.ink2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(IACollectionStore.allSelectableCollections) { collection in
                        Button {
                            toggle(collection)
                        } label: {
                            OnboardingCollectionCard(
                                collection: collection,
                                isSelected: selectedCollectionIDs.contains(collection.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var footerActions: some View {
        VStack(spacing: 10) {
            Button {
                finishAction(selectedCollectionIDs)
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .scaledFont(size: 15.5, weight: .bold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .foregroundStyle(Color(hex: 0x221503))
                    .background {
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(hex: 0xEEB35B), Color(hex: 0xCF8F34)],
                                startPoint: .top, endPoint: .bottom))
                    }
            }
            .buttonStyle(.plain)

            Button("Skip") {
                skipAction()
            }
            .scaledFont(size: 12.5)
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
    }

    private func toggle(_ collection: IACollection) {
        if selectedCollectionIDs.contains(collection.id) {
            selectedCollectionIDs.remove(collection.id)
        } else {
            selectedCollectionIDs.insert(collection.id)
        }
    }
}

private struct OnboardingCollectionCard: View {
    var collection: IACollection
    var isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CollectionArtworkView(
                title: collection.title,
                systemImage: collection.systemImage,
                assetName: collection.assetName,
                remoteImageURL: collection.remoteImageURL
            )
            .frame(width: 170, height: 170)

            Text(collection.title)
                .scaledFont(size: 13, weight: .bold)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
        }
        .frame(width: 170, alignment: .topLeading)
        .padding(10)
        .glassSurface(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.brass : .clear, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 20, weight: .bold)
                    .foregroundStyle(Palette.brass)
                    .background(Circle().fill(Color(hex: 0x221503)))
                    .padding(6)
            }
        }
    }
}

private struct CollectionSelectionChip: View {
    var collection: IACollection
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: collection.systemImage)
                    .scaledFont(size: 14, weight: .semibold)
                    .frame(width: 28, height: 28)
                Text(collection.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .scaledFont(size: 14, weight: .bold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .padding(.horizontal, 12)
            .foregroundStyle(isSelected ? Color(hex: 0x221503) : Palette.ink)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Palette.brass : Color.white.opacity(0.08))
            }
            .overlay {
                if !isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Palette.hairline, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(collection.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
