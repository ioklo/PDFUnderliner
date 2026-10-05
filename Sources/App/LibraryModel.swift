import Foundation
import PDFKit
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    @Published var documents: [LibraryDocument] = []
    @Published var error: String?
    @Published var importing = false
    let repository: DocumentRepository?
    /// One queue is shared with the reader so a queued save always precedes deletion.
    let persistence = DispatchQueue(label: "PDFUnderliner.persistence", qos: .userInitiated)

    init() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            repository = try DocumentRepository(root: support.appendingPathComponent("Documents", isDirectory: true))
        } catch {
            repository = nil
            self.error = "저장소를 열 수 없습니다: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        guard let repository else { return }
        persistence.async { [weak self] in
            let result = Result { try repository.list() }
            DispatchQueue.main.async {
                switch result {
                case .success(let documents): self?.documents = documents
                case .failure(let error): self?.error = "문서 목록을 읽을 수 없습니다: \(error.localizedDescription)"
                }
            }
        }
    }

    func importPDF(_ url: URL) {
        guard let repository else { return }
        importing = true
        persistence.async { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let result = Result<LibraryDocument, Error> {
                guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
                    throw ImportError.unreadable
                }
                guard !pdf.isEncrypted, !pdf.isLocked else { throw ImportError.encrypted }
                return try repository.importDocument(from: url, title: url.deletingPathExtension().lastPathComponent,
                                                     pageCount: pdf.pageCount)
            }
            DispatchQueue.main.async {
                self?.importing = false
                switch result {
                case .success: self?.refresh()
                case .failure(let error): self?.error = error.localizedDescription
                }
            }
        }
    }

    func delete(_ document: LibraryDocument) {
        guard let repository else { return }
        persistence.async { [weak self] in
            let result = Result { try repository.delete(document) }
            DispatchQueue.main.async {
                if case .failure(let error) = result { self?.error = "삭제할 수 없습니다: \(error.localizedDescription)" }
                self?.refresh()
            }
        }
    }
}

private enum ImportError: LocalizedError {
    case unreadable, encrypted
    var errorDescription: String? {
        switch self {
        case .unreadable: return "이 파일은 읽을 수 있는 PDF가 아닙니다."
        case .encrypted: return "암호화된 PDF는 아직 지원하지 않습니다. 암호가 없는 PDF를 가져와 주세요."
        }
    }
}
