import XCTest
import UIKit
import PDFKit
import PencilKit
import Combine
import SwiftUI
@testable import PDFUnderliner

@MainActor
final class ReaderSessionTests: XCTestCase {
    private var temporary: URL!
    private var repository: DocumentRepository!
    private var document: LibraryDocument!
    private let persistence = DispatchQueue(label: "ReaderSessionTests.persistence")

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let source = temporary.appendingPathComponent("fixture.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: source) { context in
            context.beginPage()
            ("PDF remains unchanged" as NSString).draw(at: CGPoint(x: 40, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage(withBounds: CGRect(x: 0, y: 0, width: 600, height: 400), pageInfo: [:])
        }
        repository = try DocumentRepository(root: temporary.appendingPathComponent("library"))
        document = try repository.importDocument(from: source, title: "Fixture", pageCount: 2)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func open(repository: DocumentRepository? = nil) async -> ReaderSession {
        let session = ReaderSession(document: document, repository: repository ?? self.repository, persistence: persistence)
        await waitFor(session) { !$0.loading }
        return session
    }

    private func waitFor(_ session: ReaderSession, predicate: @escaping (ReaderSession) -> Bool) async {
        if predicate(session) { return }
        let expectation = expectation(description: "Session state")
        var fulfilled = false
        let token = session.objectWillChange.sink {
            DispatchQueue.main.async {
                if !fulfilled && predicate(session) { fulfilled = true; expectation.fulfill() }
            }
        }
        await fulfillment(of: [expectation], timeout: 5)
        token.cancel()
    }

    private func stroke(color: UIColor = .black, ink: PKInk.InkType = .pen) -> PKDrawing {
        let points = [CGPoint(x: 40, y: 100), CGPoint(x: 120, y: 105)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        return PKDrawing(strokes: [PKStroke(ink: PKInk(ink, color: color), path: path)])
    }

    func testNativeDrawingRoundTripAndPDFHash() async throws {
        let session = await open()
        let hash = try DocumentRepository.sha256(of: repository.sourceURL(for: document.id))
        let drawing = stroke()
        let marker = stroke(color: .yellow.withAlphaComponent(0.35), ink: .marker)
        session.drawingChanged(drawing, page: 0)
        session.drawingChanged(marker, page: 1)
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        let reopened = await open()
        XCTAssertEqual(reopened.drawing(for: 0).strokes.count, 1)
        XCTAssertEqual(reopened.drawing(for: 1).strokes.first?.ink.inkType, .marker)
        XCTAssertEqual(try DocumentRepository.sha256(of: repository.sourceURL(for: document.id)), hash)
        reopened.flush()
        await waitFor(reopened) { !$0.hasUnsavedChanges && !$0.isSaving }
    }

    func testUndoRedoArePageLocalAndLastStrokeDeletionPersists() async throws {
        let session = await open()
        let first = stroke()
        let second = stroke(color: .blue)
        session.drawingChanged(first, page: 0)
        session.commitHistory(before: PKDrawing(), after: first, page: 0)
        session.drawingChanged(second, page: 1)
        session.commitHistory(before: PKDrawing(), after: second, page: 1)
        session.selectPage(0)
        session.undo()
        XCTAssertTrue(session.drawing(for: 0).strokes.isEmpty)
        XCTAssertEqual(session.drawing(for: 1).strokes.count, 1)
        session.redo()
        XCTAssertEqual(session.drawing(for: 0).strokes.count, 1)
        session.undo()
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        XCTAssertNil(try repository.loadAnnotations(for: document).drawings[0])
        XCTAssertNotNil(try repository.loadAnnotations(for: document).drawings[1])
    }

    func testCorruptDrawingOpensReadOnlyAndIsNeverOverwritten() async throws {
        let annotations = AnnotationFile(document: document, drawings: [0: Data("invalid PKDrawing".utf8)])
        try repository.saveAnnotations(annotations, for: document)
        let url = repository.annotationsURL(for: document.id)
        let original = try Data(contentsOf: url)
        let session = await open()
        XCTAssertNotNil(session.pdf)
        XCTAssertNotNil(session.readOnlyReason)
        XCTAssertFalse(session.writable)
        session.drawingChanged(stroke(), page: 0)
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testFailedSaveKeepsDrawingAndRetryWritesIt() async throws {
        final class FailureSwitch: @unchecked Sendable { var fail = true }
        let failure = FailureSwitch()
        let failing = try DocumentRepository(root: repository.root) { data, url in
            if url.lastPathComponent == "annotations.plist", failure.fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let session = await open(repository: failing)
        session.drawingChanged(stroke(), page: 0)
        session.flush()
        await waitFor(session) { $0.saveError != nil }
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(session.drawing(for: 0).strokes.count, 1)
        failure.fail = false
        session.retrySave()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        XCTAssertNil(session.saveError)
        XCTAssertNotNil(try repository.loadAnnotations(for: document).drawings[0])
    }

    func testOverlayKeepsPDFCoordinatesThroughResizing() async {
        let session = await open()
        let drawing = stroke()
        session.drawingChanged(drawing, page: 0)
        let overlay = DrawingOverlay(page: 0, size: CGSize(width: 400, height: 600), session: session)
        for size in [CGSize(width: 200, height: 300), CGSize(width: 800, height: 1200), CGSize(width: 400, height: 600)] {
            overlay.frame = CGRect(origin: .zero, size: size)
            overlay.setNeedsLayout()
            overlay.layoutIfNeeded()
            XCTAssertEqual(overlay.canvas.bounds.size, CGSize(width: 400, height: 600))
            XCTAssertEqual(overlay.canvas.drawing.strokes.first?.path.first?.location, CGPoint(x: 40, y: 100))
        }
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
    }

    func testPDFKitOverlayAlignmentThroughModesZoomAndPageRotation() async throws {
        // Build immutable, pre-rotated pages: the reader never edits page rotation at runtime.
        let source = temporary.appendingPathComponent("rotated.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: source) { context in
            for _ in 0..<4 { context.beginPage() }
        }
        let fixture = try XCTUnwrap(PDFDocument(url: source))
        for index in 0..<4 {
            let page = try XCTUnwrap(fixture.page(at: index))
            page.rotation = index * 90
            page.setBounds(CGRect(x: 20, y: 30, width: 360, height: 520), for: .cropBox)
        }
        XCTAssertTrue(fixture.write(to: source))
        document = try repository.importDocument(from: source, title: "Rotated fixture", pageCount: 4)
        let session = await open()
        let pdf = try XCTUnwrap(session.pdf)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let view = ReaderPDFView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.autoScales = true
        view.isInMarkupMode = true
        controller.view.addSubview(view)
        let coordinator = PDFReaderView.Coordinator(session: session)
        view.pageOverlayViewProvider = coordinator
        coordinator.attach(view)
        window.makeKeyAndVisible()
        defer { coordinator.detach(); window.isHidden = true }

        for mode in ReadingMode.allCases {
            coordinator.configure(document: pdf, mode: mode)
            try await Task.sleep(nanoseconds: 200_000_000)
            for index in 0..<4 {
                let page = try XCTUnwrap(pdf.page(at: index))
                view.layoutDocumentView()
                view.go(to: page)
                try await Task.sleep(nanoseconds: 200_000_000)
                for zoom in [view.scaleFactor, view.scaleFactor * 1.5] {
                    view.scaleFactor = zoom
                    view.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let overlay = try XCTUnwrap(descendants(of: view, type: DrawingOverlay.self).first { $0.page == index })
                    let local = CGPoint(x: 80, y: 100)
                    let crop = page.bounds(for: .cropBox)
                    let expected = view.convert(CGPoint(x: crop.minX + local.x, y: crop.maxY - local.y), from: page)
                    let actual = overlay.canvas.convert(local, to: view)
                    XCTAssertEqual(actual.x, expected.x, accuracy: 2, "\(mode), rotation \(page.rotation)")
                    XCTAssertEqual(actual.y, expected.y, accuracy: 2, "\(mode), rotation \(page.rotation)")
                    XCTAssertEqual(overlay.canvas.drawingPolicy, .pencilOnly)
                    XCTAssertFalse(overlay.canvas.isScrollEnabled)
                }
            }
        }
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
    }

    func testLongDocumentDoesNotKeepEveryCanvas() async throws {
        let source = temporary.appendingPathComponent("long.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: source) { context in
            for index in 0..<200 {
                context.beginPage()
                ("Page \(index + 1)" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: nil)
            }
        }
        document = try repository.importDocument(from: source, title: "Long fixture", pageCount: 200)
        let session = await open()
        let pdf = try XCTUnwrap(session.pdf)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let view = ReaderPDFView(frame: window.bounds)
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.autoScales = true
        view.isInMarkupMode = true
        controller.view.addSubview(view)
        let coordinator = PDFReaderView.Coordinator(session: session)
        view.pageOverlayViewProvider = coordinator
        coordinator.attach(view)
        window.makeKeyAndVisible()
        defer { coordinator.detach(); window.isHidden = true }
        coordinator.configure(document: pdf, mode: .continuous)
        try await Task.sleep(nanoseconds: 200_000_000)
        for index in [0, 1, 50, 100, 199, 0] {
            view.go(to: try XCTUnwrap(pdf.page(at: index)))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertLessThan(coordinator.activeOverlayCount, 12, "Offscreen canvas ownership must stay bounded")
        }
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
    }

    func testReaderScreenRendersPDFAndCapturePreview() async throws {
        var annotations = AnnotationFile(document: document)
        annotations.drawings[0] = stroke(color: .yellow.withAlphaComponent(0.35), ink: .marker).dataRepresentation()
        try repository.saveAnnotations(annotations, for: document)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            ReaderView(document: document, repository: repository, persistence: persistence)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 600_000_000)
        let reader = try XCTUnwrap(descendants(of: window, type: PDFView.self).first)
        XCTAssertEqual(reader.document?.pageCount, 2)
        XCTAssertFalse(descendants(of: reader, type: DrawingOverlay.self).isEmpty)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iPad mini reader preview"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Drain any metadata save scheduled by view teardown before removing its temporary library.
        window.rootViewController = nil
        try await Task.sleep(nanoseconds: 400_000_000)
        await withCheckedContinuation { continuation in persistence.async { continuation.resume() } }
    }

    func testEditsDuringSaveDoNotGetLostInAnOlderSnapshot() async throws {
        let started = expectation(description: "First drawing write began")
        let gate = DispatchSemaphore(value: 0)
        final class WriteCounter: @unchecked Sendable { var value = 0 }
        let counter = WriteCounter()
        let slow = try DocumentRepository(root: repository.root) { data, url in
            if url.lastPathComponent == "annotations.plist" {
                counter.value += 1
                if counter.value == 1 {
                    started.fulfill()
                    _ = gate.wait(timeout: .now() + 5)
                }
            }
            try data.write(to: url, options: .atomic)
        }
        let session = await open(repository: slow)
        session.drawingChanged(stroke(), page: 0)
        session.flush()
        await fulfillment(of: [started], timeout: 3)
        let next = PKDrawing(strokes: session.drawing(for: 0).strokes + stroke(color: .blue).strokes)
        session.drawingChanged(next, page: 0)
        session.flush()
        gate.signal()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        let data = try XCTUnwrap(repository.loadAnnotations(for: document).drawings[0])
        XCTAssertEqual(try PKDrawing(data: data).strokes.count, 2)
    }

    func testReopensAtSavedPDFDestination() async throws {
        let source = temporary.appendingPathComponent("position.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: source) { context in for _ in 0..<8 { context.beginPage() } }
        document = try repository.importDocument(from: source, title: "Position fixture", pageCount: 8)
        let session = await open()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let view = ReaderPDFView(frame: window.bounds)
        view.autoScales = true
        controller.view.addSubview(view)
        let coordinator = PDFReaderView.Coordinator(session: session)
        view.pageOverlayViewProvider = coordinator
        coordinator.attach(view)
        coordinator.configure(document: session.pdf, mode: .continuous)
        try await Task.sleep(nanoseconds: 200_000_000)
        let page = try XCTUnwrap(session.pdf?.page(at: 3))
        view.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 450)))
        try await Task.sleep(nanoseconds: 150_000_000)
        coordinator.capturePosition()
        let expected = session.document.position
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        coordinator.detach()
        view.removeFromSuperview()
        document = try XCTUnwrap(repository.list().first { $0.id == document.id })
        let reopened = await open()
        let restored = ReaderPDFView(frame: window.bounds)
        restored.autoScales = true
        controller.view.addSubview(restored)
        let restoredCoordinator = PDFReaderView.Coordinator(session: reopened)
        restored.pageOverlayViewProvider = restoredCoordinator
        restoredCoordinator.attach(restored)
        defer { restoredCoordinator.detach() }
        restoredCoordinator.configure(document: reopened.pdf, mode: .continuous)
        try await Task.sleep(nanoseconds: 250_000_000)
        restoredCoordinator.capturePosition()
        XCTAssertEqual(reopened.document.position.page, expected.page)
        XCTAssertEqual(try XCTUnwrap(reopened.document.position.x), try XCTUnwrap(expected.x), accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(reopened.document.position.y), try XCTUnwrap(expected.y), accuracy: 2)
        reopened.flush()
        await waitFor(reopened) { !$0.hasUnsavedChanges && !$0.isSaving }
    }

    private func descendants<T: UIView>(of view: UIView, type: T.Type) -> [T] {
        var result = (view as? T).map { [$0] } ?? []
        for child in view.subviews { result += descendants(of: child, type: type) }
        return result
    }

    func testUndoThenDrawingIgnoresOldCanvasCallbacksForPenAndMarker() async throws {
        for ink in [PKInk.InkType.pen, .marker] {
            let session = await open()
            let overlay = DrawingOverlay(page: 0, size: CGSize(width: 400, height: 600), session: session)
            session.displayDrawing = { _, drawing in overlay.setDrawing(drawing) }
            session.finishStrokes = { overlay.finishStroke() }
            let initial = session.drawing(for: 0).strokes.count
            for color in [UIColor.red, .blue, .green] {
                overlay.canvasViewDidBeginUsingTool(overlay.canvas)
                overlay.canvas.drawing = PKDrawing(strokes: overlay.canvas.drawing.strokes + stroke(color: color, ink: ink).strokes)
                overlay.canvasViewDrawingDidChange(overlay.canvas)
                overlay.canvasViewDidEndUsingTool(overlay.canvas)
                overlay.finishStroke()
            }
            let old = overlay.canvas
            session.undo()
            XCTAssertFalse(old === overlay.canvas)
            XCTAssertNil(old.delegate)
            XCTAssertEqual(session.drawing(for: 0).strokes.count, initial + 2)
            // A late pen pressure callback and even a begin/end callback from the retired canvas.
            overlay.canvasViewDrawingDidChange(old)
            overlay.canvasViewDidBeginUsingTool(old)
            overlay.canvasViewDidEndUsingTool(old)
            XCTAssertEqual(session.drawing(for: 0).strokes.count, initial + 2)
            let current = overlay.canvas
            overlay.canvasViewDidBeginUsingTool(current)
            current.drawing = PKDrawing(strokes: current.drawing.strokes + stroke(color: .purple, ink: ink).strokes)
            overlay.canvasViewDrawingDidChange(current)
            overlay.canvasViewDidEndUsingTool(current)
            overlay.finishStroke()
            XCTAssertEqual(session.drawing(for: 0).strokes.count, initial + 3)
            XCTAssertFalse(session.canRedo)
            XCTAssertEqual(session.drawing(for: 0).strokes.last?.ink.color, UIColor.purple)
            session.undo()
            session.redo()
            XCTAssertEqual(session.drawing(for: 0).strokes.count, initial + 3)
            session.flush()
            await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
            let reopened = await open()
            XCTAssertEqual(reopened.drawing(for: 0).strokes.count, initial + 3)
            reopened.flush()
            await waitFor(reopened) { !$0.hasUnsavedChanges && !$0.isSaving }
            session.displayDrawing = nil
            session.finishStrokes = nil
        }
    }

    func testOpeningStaleListDocumentLoadsLatestPositionAndClosingFreezesIt() async throws {
        let stale = document!
        var latest = stale
        latest.position = .init(page: 1, x: 40, y: 250)
        try repository.saveMetadata(latest)
        // open() still receives the original page-zero value held by the list.
        let session = await open()
        XCTAssertEqual(session.document.position, latest.position)
        session.capturePosition = { session.rememberPosition(.init(page: 1, x: 50, y: 200)) }
        session.prepareToClose()
        let final = session.document.position
        session.rememberPosition(.init(page: 0))
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        XCTAssertEqual(try repository.loadDocument(id: stale.id).position, final)
        session.capturePosition = nil
        let reopened = await open()
        XCTAssertEqual(reopened.document.position, final)
        reopened.flush()
        await waitFor(reopened) { !$0.hasUnsavedChanges && !$0.isSaving }
    }

    func testClosingSaveFailureCanResumeEditingAndRetry() async throws {
        final class Switch: @unchecked Sendable { var fail = true }
        let failure = Switch()
        let failing = try DocumentRepository(root: repository.root) { data, url in
            if failure.fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let session = await open(repository: failing)
        session.drawingChanged(stroke(), page: 0)
        session.prepareToClose()
        await waitFor(session) { $0.saveError != nil }
        XCTAssertTrue(session.isClosing)
        session.cancelClosing()
        XCTAssertTrue(session.writable)
        session.rememberPosition(.init(page: 1))
        failure.fail = false
        session.prepareToClose()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        XCTAssertNotNil(try repository.loadAnnotations(for: document).drawings[0])
        XCTAssertEqual(try repository.loadDocument(id: document.id).position.page, 1)
    }

    func testImportNavigatesOnceAndFailureDoesNotNavigate() async throws {
        let model = LibraryModel(repository: repository)
        let done = expectation(description: "Imported document becomes destination")
        var fulfilled = false
        let token = model.$navigationPath.sink { path in
            if !path.isEmpty && !fulfilled { fulfilled = true; done.fulfill() }
        }
        let source = repository.sourceURL(for: document.id)
        model.importPDF(source)
        model.importPDF(source) // Duplicate action while importing must not import twice.
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(model.navigationPath.count, 1)
        XCTAssertNotEqual(model.navigationPath.first, document.id)
        XCTAssertTrue(model.documents.contains { $0.id == model.navigationPath.first })
        token.cancel()
        model.navigationPath.removeAll() // Back to the library.
        let failed = expectation(description: "Import failure reported")
        let errorToken = model.$error.sink { if $0 != nil { failed.fulfill() } }
        model.importPDF(temporary.appendingPathComponent("missing.pdf"))
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(model.navigationPath.isEmpty)
        errorToken.cancel()
    }

    func testImportedReaderAndImmediateReopenUseLatestMetadata() async throws {
        let model = LibraryModel(repository: repository)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LibraryView(model: model))
        window.makeKeyAndVisible()
        defer { window.rootViewController = nil; window.isHidden = true }
        model.importPDF(repository.sourceURL(for: document.id))
        try await Task.sleep(nanoseconds: 700_000_000)
        let id = try XCTUnwrap(model.navigationPath.first)
        XCTAssertEqual(descendants(of: window, type: PDFView.self).first?.document?.pageCount, 2)
        for _ in 0..<3 {
            model.navigationPath.removeAll()
            try await Task.sleep(nanoseconds: 400_000_000)
            var latest = try repository.loadDocument(id: id)
            latest.position = .init(page: 1) // The list deliberately still holds the earlier snapshot.
            try repository.saveMetadata(latest)
            model.navigationPath.append(id)
            try await Task.sleep(nanoseconds: 600_000_000)
            let reader = try XCTUnwrap(descendants(of: window, type: PDFView.self).first)
            let page = try XCTUnwrap(reader.currentPage)
            XCTAssertEqual(reader.document?.index(for: page), 1)
        }
        model.navigationPath.removeAll()
        try await Task.sleep(nanoseconds: 400_000_000)
        await withCheckedContinuation { continuation in model.persistence.async { continuation.resume() } }
    }

    func testPositionIsNotCapturedUntilPDFJoinsAWindow() async throws {
        var latest = document!
        latest.position = .init(page: 1)
        try repository.saveMetadata(latest)
        let session = await open()
        let view = ReaderPDFView(frame: .zero)
        view.autoScales = true
        let coordinator = PDFReaderView.Coordinator(session: session)
        view.pageOverlayViewProvider = coordinator
        coordinator.attach(view)
        coordinator.configure(document: session.pdf, mode: .continuous)
        session.flush()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
        XCTAssertEqual(try repository.loadDocument(id: document.id).position, latest.position)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        // SwiftUI supplies the representable's final frame after attaching it to the window.
        view.frame = controller.view.bounds
        view.setNeedsLayout()
        view.layoutIfNeeded()
        defer { coordinator.detach(); window.isHidden = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(view.bounds.width, 0)
        XCTAssertEqual(view.document?.index(for: try XCTUnwrap(view.currentPage)), 1,
                       "Delayed layout: bounds=\(view.bounds), scale=\(view.scaleFactor)")
        session.prepareToClose()
        await waitFor(session) { !$0.hasUnsavedChanges && !$0.isSaving }
    }
}
