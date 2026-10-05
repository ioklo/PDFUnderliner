import XCTest
@testable import PDFUnderlinerCore

final class DocumentRepositoryTests: XCTestCase {
    private var temporary: URL!
    private var repository: DocumentRepository!
    private var source: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        repository = try DocumentRepository(root: temporary.appendingPathComponent("library"))
        source = temporary.appendingPathComponent("original.pdf")
        // Import validation belongs to PDFKit in the app; storage must copy any bytes without rewriting.
        try Data("%PDF-1.4\nfixture bytes\n%%EOF".utf8).write(to: source)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    func testImportAndDrawingRoundTripNeverRewritePDF() throws {
        let document = try repository.importDocument(from: source, title: "Reading", pageCount: 3)
        let original = try DocumentRepository.sha256(of: source)
        var annotations = try repository.loadAnnotations(for: document)
        annotations.drawings = [0: Data([1, 2, 3]), 2: Data([4, 5, 6])]
        try repository.saveAnnotations(annotations, for: document)
        let reopened = try DocumentRepository(root: repository.root)
        XCTAssertEqual(try reopened.loadAnnotations(for: document), annotations)
        XCTAssertEqual(try DocumentRepository.sha256(of: repository.sourceURL(for: document.id)), original)
        XCTAssertEqual(try Data(contentsOf: repository.sourceURL(for: document.id)), try Data(contentsOf: source))
        XCTAssertEqual(try repository.list().map(\.id), [document.id])
        let bytes = try Data(contentsOf: repository.annotationsURL(for: document.id))
        XCTAssertEqual(String(data: bytes.prefix(8), encoding: .ascii), "bplist00")
        XCTAssertLessThan(bytes.count, 2048)
    }

    func testDeletingLastStrokePersistsEmptyPageWithoutLosingOtherPages() throws {
        let document = try repository.importDocument(from: source, title: "Reading", pageCount: 2)
        var annotations = AnnotationFile(document: document, drawings: [0: Data([1]), 1: Data([2])])
        try repository.saveAnnotations(annotations, for: document)
        annotations.drawings.removeValue(forKey: 0)
        try repository.saveAnnotations(annotations, for: document)
        XCTAssertEqual(try repository.loadAnnotations(for: document).drawings, [1: Data([2])])
    }

    func testSameNameImportsAreIndependentAndDeleteLeavesOriginal() throws {
        let first = try repository.importDocument(from: source, title: "Same name", pageCount: 1)
        let second = try repository.importDocument(from: source, title: "Same name", pageCount: 1)
        XCTAssertNotEqual(first.id, second.id)
        try repository.delete(first)
        XCTAssertEqual(try repository.list().map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.sourceURL(for: second.id).path))
    }

    func testRecentOrderAndReadingPositionRoundTrip() throws {
        var first = try repository.importDocument(from: source, title: "A", pageCount: 2)
        let second = try repository.importDocument(from: source, title: "B", pageCount: 2)
        first.position = .init(page: 1, x: 28.5, y: 150)
        first.lastOpened = second.lastOpened.addingTimeInterval(1)
        try repository.saveMetadata(first)
        let list = try repository.list()
        XCTAssertEqual(list.first, first)
        XCTAssertEqual(list.first?.position, .init(page: 1, x: 28.5, y: 150))
    }

    func testCorruptAndMissingSidecarsAreNotReplacedOnRead() throws {
        let document = try repository.importDocument(from: source, title: "Reading", pageCount: 1)
        let url = repository.annotationsURL(for: document.id)
        let corrupt = Data("broken sidecar".utf8)
        try corrupt.write(to: url)
        XCTAssertThrowsError(try repository.loadAnnotations(for: document))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try repository.loadAnnotations(for: document))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMismatchedIdentityAndChangedPDFRejected() throws {
        let first = try repository.importDocument(from: source, title: "A", pageCount: 1)
        let second = try repository.importDocument(from: source, title: "B", pageCount: 1)
        XCTAssertThrowsError(try repository.saveAnnotations(AnnotationFile(document: second), for: first))
        try FileManager.default.copyItem(at: repository.annotationsURL(for: second.id), to: temporary.appendingPathComponent("copy"))
        let foreign = try Data(contentsOf: repository.annotationsURL(for: second.id))
        try foreign.write(to: repository.annotationsURL(for: first.id))
        XCTAssertThrowsError(try repository.loadAnnotations(for: first))
        try repository.saveAnnotations(AnnotationFile(document: first), for: first)
        try Data("changed".utf8).write(to: repository.sourceURL(for: first.id))
        XCTAssertThrowsError(try repository.loadAnnotations(for: first))
    }

    func testInvalidPageAndUnknownVersionRejected() throws {
        let document = try repository.importDocument(from: source, title: "A", pageCount: 1)
        XCTAssertThrowsError(try repository.saveAnnotations(AnnotationFile(document: document, drawings: [1: Data([1])]), for: document))
        let url = repository.annotationsURL(for: document.id)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        plist["formatVersion"] = 99
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        XCTAssertThrowsError(try repository.loadAnnotations(for: document))
    }

    func testFailedWritePreservesPreviousFileAndRetrySucceeds() throws {
        let document = try repository.importDocument(from: source, title: "A", pageCount: 1)
        let oldBytes = try Data(contentsOf: repository.annotationsURL(for: document.id))
        var fail = true
        let failing = try DocumentRepository(root: repository.root) { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let annotations = AnnotationFile(document: document, drawings: [0: Data([7, 8, 9])])
        XCTAssertThrowsError(try failing.saveAnnotations(annotations, for: document))
        XCTAssertEqual(try Data(contentsOf: repository.annotationsURL(for: document.id)), oldBytes)
        fail = false
        try failing.saveAnnotations(annotations, for: document)
        XCTAssertEqual(try failing.loadAnnotations(for: document), annotations)
    }

    func testFailedImportCleansUpIncompleteFolder() throws {
        let failing = try DocumentRepository(root: repository.root) { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try failing.importDocument(from: source, title: "A", pageCount: 1))
        XCTAssertTrue(try repository.list().isEmpty)
    }
}
