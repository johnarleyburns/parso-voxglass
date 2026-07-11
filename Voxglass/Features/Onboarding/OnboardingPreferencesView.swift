import SwiftUI

struct OnboardingPreferencesView: View {
    var initialSelection: Set<String>
    var finishAction: (Set<String>) -> Void
    var skipAction: () -> Void

    @State private var selectedTasteIDs: Set<String>

    init(
        initialSelection: Set<String>,
        finishAction: @escaping (Set<String>) -> Void,
        skipAction: @escaping () -> Void
    ) {
        self.initialSelection = initialSelection
        self.finishAction = finishAction
        self.skipAction = skipAction
        _selectedTasteIDs = State(initialValue: initialSelection)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 142), spacing: 10)
    ]

    var body: some View {
        ZStack {
            VoxglassBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
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
                .font(.system(size: 20))
                .foregroundStyle(Palette.brass)
                .frame(width: 44, height: 44)
                .glassSurface(cornerRadius: 14)

            Text("Choose a few interests")
                .font(.system(size: 31, weight: .heavy))
                .kerning(-0.5)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Voxglass will start with popular LibriVox picks and refresh the shelf around your selections.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tasteGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(LibriVoxTaste.all) { taste in
                TasteSelectionChip(
                    taste: taste,
                    isSelected: selectedTasteIDs.contains(taste.id)
                ) {
                    toggle(taste)
                }
            }
        }
    }

    private var featuredCollections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or browse our collections")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(LibriVoxTaste.all) { taste in
                        Button {
                            toggle(taste)
                        } label: {
                            OnboardingCollectionCard(
                                collection: IACollectionStore.collection(for: taste, subtitle: taste.title),
                                isSelected: selectedTasteIDs.contains(taste.id)
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
                finishAction(selectedTasteIDs)
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .font(.system(size: 15.5, weight: .bold))
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
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
        }
    }

    private func toggle(_ taste: LibriVoxTaste) {
        if selectedTasteIDs.contains(taste.id) {
            selectedTasteIDs.remove(taste.id)
        } else {
            selectedTasteIDs.insert(taste.id)
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
            .frame(width: 170, height: 118)

            Text(collection.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)
        }
        .frame(width: 190, alignment: .topLeading)
        .padding(10)
        .glassSurface(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Palette.brass : .clear, lineWidth: 2)
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Palette.brass)
                    .background(Circle().fill(Color(hex: 0x221503)))
                    .padding(6)
            }
        }
    }
}

private struct TasteSelectionChip: View {
    var taste: LibriVoxTaste
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: taste.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text(taste.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
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
        .accessibilityLabel(taste.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
