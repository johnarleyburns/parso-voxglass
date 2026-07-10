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
                .font(.title2)
                .foregroundStyle(VoxglassTheme.accent)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(VoxglassTheme.paperRaised)
                }

            Text("Choose a few interests")
                .font(.system(.largeTitle, design: .serif, weight: .bold))
                .foregroundStyle(VoxglassTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("Voxglass will start with popular LibriVox picks and refresh the shelf around your selections.")
                .font(.subheadline)
                .foregroundStyle(VoxglassTheme.secondaryInk)
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

    private var footerActions: some View {
        VStack(spacing: 10) {
            Button {
                finishAction(selectedTasteIDs)
            } label: {
                Label("Continue", systemImage: "arrow.right")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(VoxglassTheme.deepGlass)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(VoxglassTheme.accent)
                    }
            }
            .buttonStyle(.plain)

            Button("Skip") {
                skipAction()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(VoxglassTheme.secondaryInk)
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

private struct TasteSelectionChip: View {
    var taste: LibriVoxTaste
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: taste.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
                Text(taste.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .padding(.horizontal, 12)
            .foregroundStyle(isSelected ? VoxglassTheme.deepGlass : VoxglassTheme.ink)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? VoxglassTheme.accent : VoxglassTheme.paperRaised)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? VoxglassTheme.warmLine : VoxglassTheme.softLine, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(taste.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
