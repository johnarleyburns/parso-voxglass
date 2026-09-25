import SwiftUI

/// Shared typography tokens for the iOS 26 visual system.
enum VoxglassType: Equatable {
    case screenTitle, heroTitle, bookTitle, collectionTitle, section, body, meta, eyebrow, timecode

    fileprivate var font: Font {
        switch self {
        case .screenTitle: .largeTitle
        case .heroTitle: .title2
        case .bookTitle: .headline
        case .collectionTitle: .title3
        case .section: .headline
        case .body: .subheadline
        case .meta: .footnote
        case .eyebrow: .caption2
        case .timecode: .caption
        }
    }

    fileprivate var weight: Font.Weight {
        switch self {
        case .heroTitle, .collectionTitle: .semibold
        case .bookTitle: .medium
        case .section: .bold
        case .eyebrow: .semibold
        case .timecode: .medium
        default: .regular
        }
    }
}

struct VoxglassTypeModifier: ViewModifier {
    let token: VoxglassType

    func body(content: Content) -> some View {
        content
            .font(token.font)
            .fontWeight(token.weight)
            .fontDesign([.heroTitle, .bookTitle, .collectionTitle].contains(token) ? .serif : .default)
            .tracking(token == .eyebrow ? 0.6 : 0)
            .textCase(token == .eyebrow ? .uppercase : nil)
            .modifier(MonospacedDigitsModifier(enabled: token == .timecode))
    }
}

private struct MonospacedDigitsModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View { enabled ? AnyView(content.monospacedDigit()) : AnyView(content) }
}

extension View {
    func voxType(_ token: VoxglassType) -> some View { modifier(VoxglassTypeModifier(token: token)) }
}

enum Radius {
    static let card: CGFloat = 20
    static let tile: CGFloat = 10
    static let plateSmall: CGFloat = 6
    static let plateLarge: CGFloat = 14
}

enum Spacing {
    static let gutter: CGFloat = 16
    static let section: CGFloat = 24
}

enum Motion {
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let pauseScale: CGFloat = 0.88
}
