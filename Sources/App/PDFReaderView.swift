import SwiftUI
import PDFKit
import PencilKit

struct PDFReaderView: UIViewRepresentable {
    @ObservedObject var session: ReaderSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.backgroundColor = .secondarySystemBackground
        view.autoScales = true
        view.isInMarkupMode = true
        view.pageOverlayViewProvider = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: ReaderPDFView, context: Context) {
        context.coordinator.configure(document: session.pdf, mode: session.mode)
        context.coordinator.updateTools()
    }

    static func dismantleUIView(_ view: ReaderPDFView, coordinator: Coordinator) {
        coordinator.detach()
        view.pageOverlayViewProvider = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFPageOverlayViewProvider {
        let session: ReaderSession
        weak var view: ReaderPDFView?
        private var overlays: [Int: DrawingOverlay] = [:]
        private var mode: ReadingMode?
        private var restorePosition: ReadingPosition?
        private var restoring = false
        private var positionTimer: Timer?
        private var observers: [NSObjectProtocol] = []
        private var appliedSettings: ToolSettings?
        private var appliedWritable: Bool?
        private var detached = false
        private var waitingForTransition = false

        /// Diagnostics for bounding overlay ownership while navigating large documents.
        var activeOverlayCount: Int { overlays.count }

        init(session: ReaderSession) { self.session = session }

        func attach(_ view: ReaderPDFView) {
            self.view = view
            view.onLayout = { [weak self] in self?.didLayout() }
            session.displayDrawing = { [weak self] page, drawing in self?.overlays[page]?.setDrawing(drawing) }
            session.finishStrokes = { [weak self] in self?.finishStrokes() }
            session.capturePosition = { [weak self] in self?.capturePosition() }
            observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged,
                object: view, queue: .main) { [weak self] _ in
                    // PDFKit also notifies synchronously during SwiftUI's updateUIView.
                    // Publish page changes on the next turn, outside that update transaction.
                    DispatchQueue.main.async { self?.pageChanged() }
                })
            // Public PDFKit APIs expose the current destination but no scroll-position delegate.
            positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.didLayout(); self?.capturePosition() }
            }
        }

        func configure(document: PDFDocument?, mode: ReadingMode) {
            guard let view, let document else { return }
            var layoutChanged = false
            if view.document !== document {
                restorePosition = session.document.position
                view.document = document
                layoutChanged = true
            }
            if self.mode != mode {
                finishStrokes()
                if self.mode != nil { capturePosition(); restorePosition = session.document.position }
                self.mode = mode
                view.usePageViewController(mode == .paged, withViewOptions: nil)
                view.displayDirection = mode == .continuous ? .vertical : .horizontal
                view.displayMode = mode == .continuous ? .singlePageContinuous : .singlePage
                view.displaysPageBreaks = true
                view.autoScales = true
                view.setNeedsLayout()
                layoutChanged = true
            }
            if layoutChanged { didLayout() }
        }

        private func didLayout() {
            guard !detached, let view else { return }
            restrictNavigationTouches(in: view)
            guard !restoring, !waitingForTransition, !session.isClosing,
                  let position = restorePosition, view.window != nil,
                  view.bounds.width > 0, view.bounds.height > 0,
                  let page = view.document?.page(at: position.page) else { return }
            var responder: UIResponder? = view
            while let candidate = responder, !(candidate is UIViewController) { responder = candidate.next }
            if let transition = (responder as? UIViewController)?.transitionCoordinator, transition.isAnimated {
                waitingForTransition = true
                let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.waitingForTransition = false
                    self?.didLayout()
                }
                if registered { return }
                waitingForTransition = false
            }
            restoring = true
            // Layout is deferred to avoid moving a destination before PDFKit sizes its pages.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.detached else { return }
                view.layoutIfNeeded()
                guard view.window != nil, let scroll = self.documentScrollView(in: view),
                      scroll.contentSize.width > 0, scroll.contentSize.height > 0, view.scaleFactor > 0 else {
                    self.restoring = false
                    return
                }
                if self.mode == .continuous, let x = position.x, let y = position.y {
                    let point = CGPoint(x: x, y: y)
                    view.go(to: PDFDestination(page: page, at: point))
                    view.layoutIfNeeded()
                    self.alignViewport(to: point, on: page, in: view)
                } else { view.go(to: page) }
                let bounds = view.bounds
                let scale = view.scaleFactor
                let contentSize = scroll.contentSize
                // Keep capture blocked through PDFKit's deferred layout and navigation notifications.
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view, !self.detached else { return }
                    self.restoring = false
                    if view.bounds != bounds || view.scaleFactor != scale || scroll.contentSize != contentSize {
                        self.didLayout()
                        return
                    }
                    self.restorePosition = nil
                    self.pageChanged()
                }
            }
        }

        private func restrictNavigationTouches(in root: UIView) {
            // Canvas descendants retain PencilKit's own recognizers. PDF navigation accepts fingers only.
            if root is DrawingOverlay || root is PKCanvasView { return }
            for gesture in root.gestureRecognizers ?? [] {
                gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                if gesture is UILongPressGestureRecognizer { gesture.isEnabled = false }
            }
            for child in root.subviews { restrictNavigationTouches(in: child) }
        }

        func updateTools() {
            let settingsChanged = appliedSettings != session.toolSettings
            let writableChanged = appliedWritable != session.writable
            guard settingsChanged || writableChanged else { return }
            for overlay in overlays.values {
                // Replacing a PKTool during autosave can interrupt an in-progress Pencil stroke.
                if settingsChanged { overlay.canvas.tool = session.toolSettings.pencilTool }
                if writableChanged { overlay.canvas.drawingGestureRecognizer.isEnabled = session.writable }
            }
            appliedSettings = session.toolSettings
            appliedWritable = session.writable
        }

        private func pageChanged() {
            guard !detached, !session.isClosing, !restoring, restorePosition == nil,
                  let view, let page = view.currentPage, let document = view.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            session.selectPage(index)
            capturePosition()
        }

        func capturePosition() {
            guard !detached, !session.isClosing, !restoring, restorePosition == nil,
                  let view, view.window != nil, let document = view.document else { return }
            let anchor = CGPoint(x: view.bounds.midX, y: view.bounds.minY + 1)
            guard let page = mode == .paged ? view.currentPage : view.page(for: anchor, nearest: true) else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            // currentDestination follows PDFKit's current page rather than a stable viewport anchor;
            // feeding it back into go(to:) can progressively move to the following page.
            let point = view.convert(anchor, to: page)
            // Half-point rounding prevents insignificant layout noise from constantly saving metadata.
            session.rememberPosition(.init(page: index,
                x: point.x.isFinite ? (point.x * 2).rounded() / 2 : nil,
                y: point.y.isFinite ? (point.y * 2).rounded() / 2 : nil))
        }

        private func alignViewport(to point: CGPoint, on page: PDFPage, in view: PDFView) {
            // Locate the containing scroll view through public UIView ancestry, without depending
            // on PDFKit's private class names. go(to:) supplies page loading; this corrects its anchor.
            guard let scroll = documentScrollView(in: view) else { return }
            let target = scroll.convert(view.convert(point, from: page), from: view)
            let anchor = scroll.convert(CGPoint(x: view.bounds.midX, y: view.bounds.minY + 1), from: view)
            let inset = scroll.adjustedContentInset
            let minimum = CGPoint(x: -inset.left, y: -inset.top)
            let maximum = CGPoint(x: max(minimum.x, scroll.contentSize.width - scroll.bounds.width + inset.right),
                                  y: max(minimum.y, scroll.contentSize.height - scroll.bounds.height + inset.bottom))
            let offset = CGPoint(x: min(maximum.x, max(minimum.x, scroll.contentOffset.x + target.x - anchor.x)),
                                 y: min(maximum.y, max(minimum.y, scroll.contentOffset.y + target.y - anchor.y)))
            scroll.setContentOffset(offset, animated: false)
        }

        private func documentScrollView(in view: PDFView) -> UIScrollView? {
            var ancestor = view.documentView?.superview
            while let candidate = ancestor, !(candidate is UIScrollView) { ancestor = candidate.superview }
            return ancestor as? UIScrollView
        }

        func finishStrokes() { for overlay in overlays.values { overlay.finishStroke() } }

        func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let document = pdfView.document else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            if let existing = overlays[index] { return existing }
            let overlay = DrawingOverlay(page: index, size: page.bounds(for: .cropBox).size, session: session)
            overlays[index] = overlay
            return overlay
        }

        func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
            updateTools()
            restrictNavigationTouches(in: pdfView)
        }

        func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let overlay = overlayView as? DrawingOverlay else { return }
            overlay.finishStroke()
            // PDFKit may deliver a late callback for an old overlay after rebuilding its layout.
            if overlays[overlay.page] === overlay { overlays.removeValue(forKey: overlay.page) }
            session.flush(captureReadingPosition: false)
        }

        func detach() {
            detached = true
            session.flush(captureReadingPosition: false)
            positionTimer?.invalidate()
            positionTimer = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            overlays.removeAll()
            session.displayDrawing = nil
            session.finishStrokes = nil
            session.capturePosition = nil
            view?.onLayout = nil
        }
    }
}

final class ReaderPDFView: PDFView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout?()
    }
}

@MainActor
final class DrawingOverlay: UIView, PKCanvasViewDelegate {
    let page: Int
    private(set) var canvas = PKCanvasView()
    private let pageSize: CGSize
    private weak var session: ReaderSession?
    private var beforeStroke: PKDrawing?
    private var settlement: DispatchWorkItem?
    private var drawingActive = false

    init(page: Int, size: CGSize, session: ReaderSession) {
        self.page = page
        pageSize = size
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: size))
        backgroundColor = .clear
        clipsToBounds = true
        canvas = makeCanvas(drawing: session.drawing(for: page))
        addSubview(canvas)
    }

    private func makeCanvas(drawing: PKDrawing) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.drawingGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        canvas.isScrollEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.bounces = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.drawing = drawing
        canvas.tool = session?.toolSettings.pencilTool ?? ToolSettings().pencilTool
        canvas.drawingGestureRecognizer.isEnabled = session?.writable ?? false
        canvas.delegate = self
        return canvas
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        // Keep drawing coordinates fixed in PDF points. PDFKit rotates the enclosing overlay itself.
        canvas.bounds = CGRect(origin: .zero, size: pageSize)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = CGAffineTransform(scaleX: bounds.width / pageSize.width, y: bounds.height / pageSize.height)
        canvas.contentSize = pageSize
    }

    func setDrawing(_ drawing: PKDrawing) {
        settlement?.cancel()
        settlement = nil
        beforeStroke = nil
        drawingActive = false
        canvas.delegate = nil
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.removeFromSuperview()
        // A fresh canvas discards PencilKit's pending pen samples and internal editing state.
        canvas = makeCanvas(drawing: drawing)
        addSubview(canvas)
        setNeedsLayout()
        layoutIfNeeded()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        finishStroke()
        session?.selectPage(page)
        beforeStroke = session?.drawing(for: page) ?? canvasView.drawing
        drawingActive = true
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        // Programmatic changes may notify asynchronously. Compare with the model to avoid a new edit.
        guard beforeStroke != nil || canvasView.drawing.dataRepresentation() != session?.drawing(for: page).dataRepresentation() else { return }
        session?.drawingChanged(canvasView.drawing, page: page)
        if !drawingActive { scheduleSettlement() }
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        drawingActive = false
        // PencilKit can deliver final pressure samples AFTER this callback.
        scheduleSettlement()
    }

    private func scheduleSettlement() {
        settlement?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishStroke() }
        settlement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func finishStroke() {
        settlement?.cancel()
        settlement = nil
        guard let before = beforeStroke else { return }
        beforeStroke = nil
        drawingActive = false
        let after = canvas.drawing
        if before.dataRepresentation() != after.dataRepresentation() {
            session?.drawingChanged(after, page: page)
            session?.commitHistory(before: before, after: after, page: page)
        }
    }
}
