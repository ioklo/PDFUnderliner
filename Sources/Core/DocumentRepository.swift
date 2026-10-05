import Foundation
import CryptoKit

public struct ReadingPosition: Codable, Equatable, Sendable {
    public var page: Int
    /// Unrotated PDF coordinates, rather than screen pixels.
    public var x: Double?
    public var y: Double?

    public init(page: Int = 0, x: Double? = nil, y: Double? = nil) {
        self.page = page
        self.x = x
        self.y = y
    }
}

public struct LibraryDocument: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let pageCount: Int
    public let sourceSHA256: String
    public var lastOpened: Date
    public var position: ReadingPosition

    public init(id: UUID, title: String, pageCount: Int, sourceSHA256: String,
                lastOpened: Date = Date(), position: ReadingPosition = .init()) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.sourceSHA256 = sourceSHA256
        self.lastOpened = lastOpened
        self.position = position
    }
}

public struct AnnotationFile: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let documentID: UUID
    public let sourceSHA256: String
    public let pageCount: Int
    /// Only pages containing strokes have entries. Values are native PKDrawing data.
    public var drawings: [Int: Data]

    public init(document: LibraryDocument, drawings: [Int: Data] = [:]) {
        formatVersion = 1
        documentID = document.id
        sourceSHA256 = document.sourceSHA256
        pageCount = document.pageCount
        self.drawings = drawings
    }
}

public enum RepositoryError: LocalizedError {
    case invalidDocument, mismatchedAnnotations, missingAnnotations

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "PDF 문서 정보를 읽을 수 없습니다."
        case .mismatchedAnnotations: return "그리기 파일이 손상되었거나 이 PDF와 일치하지 않습니다. 기존 파일을 보호하기 위해 읽기만 가능합니다."
        case .missingAnnotations: return "그리기 파일을 찾을 수 없습니다. 기존 기록을 보호하기 위해 읽기만 가능합니다."
        }
    }
}

/// All filesystem operations are serialized, including imports, metadata, and sidecar writes.
/// The app calls these methods on its persistence queue, never on the drawing path.
public final class DocumentRepository: @unchecked Sendable {
    public let root: URL
    private let lock = NSRecursiveLock()
    private let write: (Data, URL) throws -> Void

    public init(root: URL, writer: @escaping (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }) throws {
        self.root = root
        self.write = writer
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func sourceURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("source.pdf") }
    public func annotationsURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("annotations.plist") }
    private func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func list() throws -> [LibraryDocument] {
        try synchronized {
            let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let documents = try folders.filter { UUID(uuidString: $0.lastPathComponent) != nil }.map {
                try PropertyListDecoder().decode(LibraryDocument.self, from: Data(contentsOf: $0.appendingPathComponent("metadata.plist")))
            }
            return documents.sorted { $0.lastOpened > $1.lastOpened }
        }
    }

    public func importDocument(from source: URL, title: String, pageCount: Int) throws -> LibraryDocument {
        try synchronized {
            guard pageCount > 0 else { throw RepositoryError.invalidDocument }
            let id = UUID()
            let destination = folder(for: id)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            do {
                // Byte-for-byte copying: PDFKit never serializes the original PDF.
                try FileManager.default.copyItem(at: source, to: sourceURL(for: id))
                let document = LibraryDocument(id: id, title: title, pageCount: pageCount,
                                               sourceSHA256: try Self.sha256(of: sourceURL(for: id)))
                try write(encode(AnnotationFile(document: document)), annotationsURL(for: id))
                try saveMetadata(document)
                return document
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    public func loadAnnotations(for document: LibraryDocument) throws -> AnnotationFile {
        try synchronized {
            let url = annotationsURL(for: document.id)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RepositoryError.missingAnnotations }
            let annotations = try PropertyListDecoder().decode(AnnotationFile.self, from: Data(contentsOf: url))
            guard annotations.formatVersion == 1, annotations.documentID == document.id,
                  annotations.sourceSHA256 == document.sourceSHA256,
                  annotations.pageCount == document.pageCount,
                  annotations.drawings.keys.allSatisfy({ (0..<document.pageCount).contains($0) }),
                  try Self.sha256(of: sourceURL(for: document.id)) == document.sourceSHA256
            else { throw RepositoryError.mismatchedAnnotations }
            return annotations
        }
    }

    public func saveAnnotations(_ annotations: AnnotationFile, for document: LibraryDocument) throws {
        try synchronized {
            guard annotations.formatVersion == 1, annotations.documentID == document.id,
                  annotations.sourceSHA256 == document.sourceSHA256,
                  annotations.pageCount == document.pageCount,
                  annotations.drawings.keys.allSatisfy({ (0..<document.pageCount).contains($0) })
            else { throw RepositoryError.mismatchedAnnotations }
            try write(encode(annotations), annotationsURL(for: document.id))
        }
    }

    public func saveMetadata(_ document: LibraryDocument) throws {
        try synchronized {
            try write(encode(document), folder(for: document.id).appendingPathComponent("metadata.plist"))
        }
    }

    public func delete(_ document: LibraryDocument) throws {
        try synchronized { try FileManager.default.removeItem(at: folder(for: document.id)) }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
