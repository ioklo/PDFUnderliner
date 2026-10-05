import SwiftUI
import PDFKit
import PencilKit

@MainActor
final class ReaderSession: ObservableObject {
    @Published var pdf: PDFDocument?
    @Published var loading = true
    @Published var openError: String?
    @Published var readOnlyReason: String?
    @Published var saveError: String?
    @Published var isSaving = false
    @Published var currentPage = 0
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var toolSettings = ToolSettings.load() { didSet { toolSettings.save() } }
    @Published var mode = ReadingMode(rawValue: UserDefaults.standard.string(forKey: "readingMode") ?? "") ?? .continuous {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "readingMode") }
    }

    private(set) var document: LibraryDocument
    let repository: DocumentRepository
    let persistence: DispatchQueue
    private var drawingData: [Int: Data] = [:]
    private var pendingDrawings: [Int: PKDrawing] = [:]
    private struct History { var undo: [PKDrawing] = []; var redo: [PKDrawing] = [] }
    private var histories: [Int: History] = [:]
    private var generation = 0
    private var savedGeneration = 0
    private var annotationGeneration = 0
    private var savedAnnotationGeneration = 0
    private var scheduledSave: DispatchWorkItem?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// Coordinator hooks let undo update a mounted canvas without retaining offscreen views.
    var displayDrawing: ((Int, PKDrawing) -> Void)?
    var finishStrokes: (() -> Void)?
    var capturePosition: (() -> Void)?

    init(document: LibraryDocument, repository: DocumentRepository, persistence: DispatchQueue) {
        self.document = document
        self.repository = repository
        self.persistence = persistence
        currentPage = document.position.page
        load()
    }

    var writable: Bool { !loading && pdf != nil && readOnlyReason == nil }
    var hasUnsavedChanges: Bool { generation != savedGeneration }

    private func load() {
        let document = document
        persistence.async { [self] in
            let result = Result { () -> AnnotationFile in
                let file = try repository.loadAnnotations(for: document)
                // Validate every stored drawing before enabling edits. Never silently replace corrupt data.
                for data in file.drawings.values { _ = try PKDrawing(data: data) }
                return file
            }
            DispatchQueue.main.async { [self] in
                guard let loadedPDF = PDFDocument(url: repository.sourceURL(for: document.id)),
                      loadedPDF.pageCount == document.pageCount, !loadedPDF.isLocked else {
                    loading = false
                    openError = "저장된 PDF를 열 수 없습니다."
                    return
                }
                pdf = loadedPDF
                switch result {
                case .success(let file): drawingData = file.drawings
                case .failure(let error):
                    readOnlyReason = "그리기 기록을 불러오지 못했습니다. 기존 파일은 유지됩니다.\n\(error.localizedDescription)"
                }
                loading = false
                self.document.lastOpened = Date()
                generation += 1
                scheduleSave()
            }
        }
    }

    func drawing(for page: Int) -> PKDrawing {
        if let drawing = pendingDrawings[page] { return drawing }
        if let data = drawingData[page], let drawing = try? PKDrawing(data: data) { return drawing }
        return PKDrawing()
    }

    func drawingChanged(_ drawing: PKDrawing, page: Int) {
        guard writable else { return }
        pendingDrawings[page] = drawing
        generation += 1
        annotationGeneration += 1
        scheduleSave()
    }

    func commitHistory(before: PKDrawing, after: PKDrawing, page: Int) {
        guard writable, before.dataRepresentation() != after.dataRepresentation() else { return }
        var history = histories[page] ?? History()
        history.undo.append(before)
        // Bounded per-page history keeps repeated strokes practical on iPad mini 5.
        if history.undo.count > 20 { history.undo.removeFirst() }
        history.redo.removeAll()
        histories[page] = history
        updateUndoAvailability()
    }

    func undo() {
        finishStrokes?()
        var history = histories[currentPage] ?? History()
        guard let previous = history.undo.popLast() else { return }
        history.redo.append(drawing(for: currentPage))
        histories[currentPage] = history
        drawingChanged(previous, page: currentPage)
        displayDrawing?(currentPage, previous)
        updateUndoAvailability()
    }

    func redo() {
        finishStrokes?()
        var history = histories[currentPage] ?? History()
        guard let next = history.redo.popLast() else { return }
        history.undo.append(drawing(for: currentPage))
        histories[currentPage] = history
        drawingChanged(next, page: currentPage)
        displayDrawing?(currentPage, next)
        updateUndoAvailability()
    }

    func selectPage(_ page: Int) {
        guard page != currentPage else { return }
        currentPage = page
        updateUndoAvailability()
    }

    func rememberPosition(_ position: ReadingPosition) {
        guard position != document.position else { return }
        document.position = position
        generation += 1
        scheduleSave()
    }

    private func updateUndoAvailability() {
        canUndo = !(histories[currentPage]?.undo.isEmpty ?? true)
        canRedo = !(histories[currentPage]?.redo.isEmpty ?? true)
    }

    private func scheduleSave() {
        scheduledSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        scheduledSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func flush(background: Bool = false) {
        finishStrokes?()
        capturePosition?()
        scheduledSave?.cancel()
        if background, hasUnsavedChanges, backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save drawings") { [weak self] in
                self?.endBackgroundTask()
            }
        }
        save()
    }

    func retrySave() { saveError = nil; flush() }

    private func save() {
        guard !loading, pdf != nil, hasUnsavedChanges, !isSaving else { return }
        // Serialization only occurs after a short idle interval, rather than on every Pencil sample.
        for (page, drawing) in pendingDrawings {
            if drawing.strokes.isEmpty { drawingData.removeValue(forKey: page) }
            else { drawingData[page] = drawing.dataRepresentation() }
        }
        pendingDrawings.removeAll()
        let snapshot = AnnotationFile(document: document, drawings: drawingData)
        let metadata = document
        let revision = generation
        let drawingRevision = annotationGeneration
        let writeAnnotations = writable && drawingRevision != savedAnnotationGeneration
        isSaving = true
        persistence.async { [self] in
            let result = Result {
                if writeAnnotations { try repository.saveAnnotations(snapshot, for: metadata) }
                try repository.saveMetadata(metadata)
            }
            DispatchQueue.main.async { [self] in
                isSaving = false
                switch result {
                case .success:
                    savedGeneration = revision
                    if writeAnnotations { savedAnnotationGeneration = drawingRevision }
                    saveError = nil
                    if hasUnsavedChanges { save() } else { endBackgroundTask() }
                case .failure(let error):
                    saveError = "저장하지 못했습니다. 변경 내용은 메모리에 유지됩니다.\n\(error.localizedDescription)"
                    endBackgroundTask()
                }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
