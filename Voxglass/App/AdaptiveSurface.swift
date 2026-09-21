import SwiftUI
import UIKit

/// The two navigation surfaces used by Voxglass. Compact keeps the focused
/// phone tab bar; regular surfaces use persistent navigation so the content
/// never has to hide the user's place in the app.
enum VoxglassSurface: Equatable {
    case compact
    case regular

    var usesSidebar: Bool {
        self == .regular
    }
}

enum VoxglassPlatform {
    static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    static var surfaceName: String {
        isMacCatalyst ? "Mac Catalyst" : "iPhone or iPad"
    }
}

/// Shared command names keep the keyboard map visible in one place. The
/// actual bindings stay on the views that own each action, so a shortcut
/// cannot accidentally target stale navigation state.
enum VoxglassKeyboardShortcut {
    static let listen = KeyEquivalent("1")
    static let myBooks = KeyEquivalent("2")
    static let discover = KeyEquivalent("3")
    static let narration = KeyEquivalent("4")
    static let record = KeyEquivalent("r")
}

struct AdaptiveNavigationShortcuts: View {
    @Binding var selection: VoxglassTab
    @State private var textEditorIsFocused = false

    var body: some View {
        VStack(spacing: 0) {
            Button("Listen") { selection = .listen }
                .keyboardShortcut(VoxglassKeyboardShortcut.listen, modifiers: [.command])
            Button("My Books") { selection = .library }
                .keyboardShortcut(VoxglassKeyboardShortcut.myBooks, modifiers: [.command])
            Button("Discover") { selection = .discover }
                .keyboardShortcut(VoxglassKeyboardShortcut.discover, modifiers: [.command])
            Button("Narration") { selection = .narration }
                .keyboardShortcut(VoxglassKeyboardShortcut.narration, modifiers: [.command])
        }
        .frame(width: 1, height: 1)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in
            textEditorIsFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in
            textEditorIsFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in
            textEditorIsFocused = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) { _ in
            textEditorIsFocused = false
        }
        .opacity(textEditorIsFocused ? 0 : 0.01)
    }
}

struct VoxglassConditionalKeyboardShortcut: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

extension View {
    func voxglassKeyboardShortcut(
        _ key: KeyEquivalent,
        modifiers: EventModifiers = .command,
        enabled: Bool
    ) -> some View {
        modifier(VoxglassConditionalKeyboardShortcut(key: key, modifiers: modifiers, enabled: enabled))
    }
}
