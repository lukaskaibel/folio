#if os(iOS)
import UIKit

/// Undo on iPhone and iPad. UIKit's text view keeps a record of what it typed itself, which goes wrong (or is
/// cleared) when the editor changes the text too: when a list continues, a link is put in, a change comes from
/// another device. So the editor keeps the record itself, of every change to the text from wherever it comes,
/// and the text view's undo manager is this one. Typing in one place is undone in one step, as in UIKit.
final class EditorUndoManager: UndoManager {
    /// Off while UIKit's text view would register its own record of typing, which this manager doesn't keep.
    fileprivate var acceptsRegistrations = false
    fileprivate var allowsClearing = false

    override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        guard acceptsRegistrations else { return }
        super.registerUndo(withTarget: target, selector: selector, object: anObject)
    }

    override func prepare(withInvocationTarget target: Any) -> Any {
        acceptsRegistrations ? super.prepare(withInvocationTarget: target) : self
    }

    override func removeAllActions() {
        guard allowsClearing else { return }
        super.removeAllActions()
    }

    override func removeAllActions(withTarget target: Any) {
        guard allowsClearing || target is EditorController else { return }
        super.removeAllActions(withTarget: target)
    }

    /// Forgets everything: a new note is loaded.
    func clear() {
        allowsClearing = true
        removeAllActions()
        allowsClearing = false
    }
}

/// One step of undo: at `location`, the text now `inserted` long was `removed` before.
final class UndoStep {
    var location: Int
    var inserted: Int
    var removed: String
    let selection: NSRange
    /// Typing goes on in the same step until the caret goes somewhere else.
    var isTyping: Bool

    init(location: Int, inserted: Int, removed: String, selection: NSRange, isTyping: Bool) {
        self.location = location
        self.inserted = inserted
        self.removed = removed
        self.selection = selection
        self.isTyping = isTyping
    }

    var end: Int { location + inserted }
}

extension EditorController {
    /// The text changed at `range` (as it is now), replacing `removed`: a step to undo, or part of the typing going on.
    func recordChange(_ range: NSRange, removed: String) {
        guard !isLoading else { return }
        let manager = undoStack
        let typing = !isPerformingEdit && !isReplayingUndo
        if typing, let step = openStep, step.isTyping, manager.canUndo {
            // Typing on, or Backspace, right where the step ends.
            if removed.isEmpty, range.location == step.end {
                step.inserted += range.length
                return
            }
            let count = (removed as NSString).length
            if range.length == 0, range.location + count == step.end {
                if count <= step.inserted {
                    step.inserted -= count
                } else {
                    step.removed = removed.prefix(count - step.inserted) + step.removed
                    step.location -= count - step.inserted
                    step.inserted = 0
                }
                return
            }
            // What the keyboard replaces in what was just typed: marked text being composed, a word corrected.
            if range.location >= step.location, range.location + count <= step.end {
                step.inserted += range.length - count
                return
            }
        }
        let step = UndoStep(location: range.location, inserted: range.length, removed: removed, selection: previousSelection, isTyping: typing)
        openStep = step
        manager.acceptsRegistrations = true
        manager.registerUndo(withTarget: self) { editor in editor.revert(step) }
        manager.acceptsRegistrations = false
    }

    /// Puts back what a step changed, which records the opposite step for redo.
    private func revert(_ step: UndoStep) {
        guard step.end <= storage.length else { return }
        isReplayingUndo = true
        let caret = NSRange(location: step.location + (step.removed as NSString).length, length: 0)
        storage.replaceCharacters(in: NSRange(location: step.location, length: step.inserted), with: step.removed)
        isReplayingUndo = false
        openStep = nil
        setSelection(undoStack.isUndoing && step.selection.upperBound <= storage.length ? step.selection : caret)
        textChanged()
        scrollCaretIntoView()
    }

    /// The caret moved somewhere else than where typing goes on: what is typed next is a step of its own.
    func closeTypingStep(at selection: NSRange) {
        guard let step = openStep, selection.length > 0 || selection.location != step.end else { return }
        openStep = nil
    }
}
#endif
