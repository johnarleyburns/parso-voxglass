import Foundation

/// Thin wrapper over `UndoManager` for async store operations (spec §8.4).
///
/// The inverse operations the app registers are async (they hit the store),
/// so each undo registration runs its closure on a `Task`; the redo pair is
/// re-registered when the undo fires, which is what makes ⌘⇧Z work.
@MainActor
public final class StudioUndo {
    public let manager: UndoManager

    public init(manager: UndoManager = UndoManager()) {
        self.manager = manager
    }

    /// Registers an async inverse operation. `redo` re-runs the forward
    /// operation; pass an empty closure for one-shot actions (e.g. the
    /// "recording is not undoable" reselect).
    public func register(
        actionName: String,
        undo: @escaping @Sendable () async -> Void,
        redo: @escaping @Sendable () async -> Void
    ) {
        manager.registerUndo(withTarget: self) { target in
            target.manager.setActionName(actionName)
            Task { await undo() }
            target.register(actionName: actionName, undo: redo, redo: undo)
        }
    }

    /// Groups the next registered action under one undo (e.g. accept-and-advance
    /// is one gesture but performs selection + navigation).
    public func beginGrouping() {
        manager.beginUndoGrouping()
    }

    public func endGrouping() {
        manager.endUndoGrouping()
    }

    public var canUndo: Bool { manager.canUndo }
    public var undoActionName: String? { manager.undoActionName }

    public func undo() {
        manager.undo()
    }

    public func clear() {
        manager.removeAllActions()
    }
}
