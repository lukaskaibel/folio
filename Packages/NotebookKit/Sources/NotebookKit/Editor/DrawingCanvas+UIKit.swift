#if os(iOS)
import PencilKit
import UIKit

/// A drawing open for drawing on iPhone and iPad: PencilKit's own canvas over its place in the text, with the system's
/// tool picker, so Apple Pencil, its pressure and tilt, palm rejection, the ruler and the lasso work as in Notes.
/// Where you only draw with Apple Pencil (a setting of the tool picker's), a finger scrolls the note.
@MainActor
final class DrawingCanvas: PKCanvasView {
    let picture: URL
    var file: DrawingFile {
        didSet {
            if isPlaced, file.drawing != drawing { setDrawing(file.drawing) }
            if file.size != oldValue.size { setNeedsLayout() }
        }
    }
    /// Over its drawing in the text, at its size: only then does it get the strokes, which PencilKit draws for
    /// the size and place the canvas has when it gets them.
    private var isPlaced = false
    /// Drawn in since drawing mode started.
    var isEdited = false
    var hasUnsavedChanges = false
    private weak var editor: EditorController?
    private var isSettingDrawing = false
    /// The canvas's delegate. Not the canvas itself: PencilKit passes some of its own calls on to the delegate, which
    /// would go round in circles.
    private lazy var events = CanvasEvents(canvas: self)
    /// Strokes are undone here, while drawing: the text view's undo is the editor's own and takes none of PencilKit's.
    private let strokeUndo = UndoManager()

    init(picture: URL, file: DrawingFile, editor: EditorController) {
        self.picture = picture
        self.file = file
        self.editor = editor
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        drawingPolicy = .default
        isScrollEnabled = false
        bounces = false
        bouncesZoom = false
        pinchGestureRecognizer?.isEnabled = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        layer.cornerRadius = 8
        layer.borderWidth = 1
        accessibilityLabel = "Drawing"
        delegate = events
        updateEdge()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (canvas: DrawingCanvas, _: UITraitCollection) in
            canvas.updateEdge()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var undoManager: UndoManager? { strokeUndo }

    /// None of the writing bar: without a bar of its own, the canvas would show the text view's, which it is inside of.
    private let noAccessory = UIView(frame: .zero)
    override var inputAccessoryView: UIView? { noAccessory }

    /// UIKit hands the focus of a view that lets go of it to the text view it is in, which would bring up the
    /// keyboard when drawing stops: the text view doesn't take it (as for the title).
    override func resignFirstResponder() -> Bool {
        let textView = superview as? MarkdownTextView
        textView?.refusesFocus = true
        defer { textView?.refusesFocus = false }
        return super.resignFirstResponder()
    }

    private func setDrawing(_ drawing: PKDrawing) {
        isSettingDrawing = true
        self.drawing = drawing
        isSettingDrawing = false
    }

    /// The edge of the drawing's area, which shows only while drawing, as in Notes.
    private func updateEdge() {
        layer.borderColor = Theme.cardBorder.resolvedColor(with: traitCollection).cgColor
    }

    /// Over the drawing's place in the text, scaled so that the drawing is as wide as the text.
    func place(in rect: CGRect) {
        if frame != rect { frame = rect }
        let scale = rect.width / max(1, file.size.width)
        if minimumZoomScale != scale || maximumZoomScale != scale {
            minimumZoomScale = scale
            maximumZoomScale = scale
        }
        if zoomScale != scale { zoomScale = scale }
        if contentSize != rect.size { contentSize = rect.size }
        if contentOffset != .zero { contentOffset = .zero }
        if !isPlaced {
            isPlaced = true
            layoutIfNeeded()
            // An empty drawing first: a canvas whose first drawing already has strokes draws nothing at all once a
            // stroke is added to it (iOS 27).
            setDrawing(PKDrawing())
            setDrawing(file.drawing)
        }
    }

    // MARK: - Drawing

    fileprivate func drawingChanged() {
        guard !isSettingDrawing else { return }
        file.drawing = drawing
        editor?.drawingDidChange(self)
    }

    fileprivate func beganUsingTool() {
        // The tool picker goes with the drawing drawn in.
        if !isFirstResponder { _ = becomeFirstResponder() }
        editor?.canvasDidBeginStroke(self)
    }

    /// Adds a stroke as if it had been drawn, through `points` in the drawing's points (the debug remote's).
    func addStroke(through points: [CGPoint], ink: PKInk, width: CGFloat) {
        let strokePoints = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) / 60, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var drawing = self.drawing
        drawing.strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: Date())))
        replaceDrawing(with: drawing)
    }

    private func replaceDrawing(with new: PKDrawing) {
        let old = drawing
        strokeUndo.registerUndo(withTarget: self) { canvas in
            MainActor.assumeIsolated { canvas.replaceDrawing(with: old) }
        }
        drawing = new
    }
}

/// Tells a canvas what PencilKit tells its delegate.
@MainActor
private final class CanvasEvents: NSObject, PKCanvasViewDelegate {
    weak var canvas: DrawingCanvas?

    init(canvas: DrawingCanvas) {
        self.canvas = canvas
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        canvas?.drawingChanged()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        canvas?.beganUsingTool()
    }
}

/// What the shared drawing mode asks of iPhone and iPad: the keyboard goes and the system's tool picker comes, for
/// whichever canvas was drawn in last; the note keeps room under the tool picker to scroll the drawing above it.
extension EditorController: PKToolPickerObserver {
    func startDrawingInput() {
        guard let session = drawingSession else { return }
        session.toolPicker.addObserver(self)
        session.toolPicker.stateAutosaveName = "NotebookDrawing"
        if textView.isFirstResponder || textView.titleField.isFirstResponder { textView.endEditing(true) }
    }

    func stopDrawingInput(_ session: DrawingSession) {
        for canvas in session.canvases.values {
            session.toolPicker.setVisible(false, forFirstResponder: canvas)
            session.toolPicker.removeObserver(canvas)
            if canvas.isFirstResponder { _ = canvas.resignFirstResponder() }
            canvas.removeFromSuperview()
        }
        session.toolPicker.removeObserver(self)
        setDrawingInset(0)
    }

    func attachCanvas(_ canvas: DrawingCanvas) {
        textView.addSubview(canvas)
        guard let toolPicker = drawingSession?.toolPicker else { return }
        toolPicker.addObserver(canvas)
        toolPicker.setVisible(true, forFirstResponder: canvas)
    }

    func detachCanvas(_ canvas: DrawingCanvas) {
        drawingSession?.toolPicker.setVisible(false, forFirstResponder: canvas)
        drawingSession?.toolPicker.removeObserver(canvas)
        canvas.removeFromSuperview()
    }

    func focusCanvas(_ picture: URL) {
        _ = drawingSession?.canvases[picture]?.becomeFirstResponder()
        updateDrawingInset()
        // The tool picker says where it is only once it is there.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.isDrawing == true { self?.updateDrawingInset() }
        }
    }

    /// The tool picker, at the bottom of the screen.
    var drawingToolsHeight: CGFloat { textView.adjustedContentInset.bottom }

    /// Whether the note scrolls with this gesture over a drawing: always where only Apple Pencil draws, otherwise
    /// with two fingers, since one draws.
    func scrollsOverDrawing(_ pan: UIGestureRecognizer) -> Bool {
        UIPencilInteraction.prefersPencilOnlyDrawing || pan.numberOfTouches > 1
    }

    // MARK: - PKToolPickerObserver

    public func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        updateDrawingInset()
    }

    public func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        updateDrawingInset()
    }

    /// Room at the bottom of the note for the tool picker, to scroll a drawing up above it. It doesn't always tell
    /// where it is (on iPhone it opens from a button into a bar, on iPad it floats), so a bar's room is kept anyway.
    func updateDrawingInset() {
        guard let toolPicker = drawingSession?.toolPicker else { return setDrawingInset(0) }
        let obscured = toolPicker.isVisible ? toolPicker.frameObscured(in: textView) : .null
        var inset = obscured.isNull ? 0 : max(0, textView.bounds.maxY - obscured.minY - textView.safeAreaInsets.bottom)
        inset = max(inset, textView.traitCollection.horizontalSizeClass == .compact ? 96 : 120)
        setDrawingInset(inset)
    }

    private func setDrawingInset(_ inset: CGFloat) {
        guard textView.contentInset.bottom != inset else { return }
        textView.contentInset.bottom = inset
        textView.verticalScrollIndicatorInsets.bottom = inset
    }
}
#endif
