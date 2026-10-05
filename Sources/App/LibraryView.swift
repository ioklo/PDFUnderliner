import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var model: LibraryModel
    @State private var showImporter = false
    @State private var pendingDelete: LibraryDocument?

    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            Group {
                if model.documents.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "book.closed").font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
                        Text("읽고, 자유롭게 줄을 그으세요").font(.title2.bold())
                        Text("PDF는 그대로, 그린 선은 따로 저장됩니다.").foregroundStyle(.secondary)
                        Button("PDF 가져오기") { showImporter = true }.buttonStyle(.borderedProminent)
                            .disabled(model.repository == nil)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(model.documents) { document in
                            if model.repository != nil {
                                NavigationLink(value: document.id) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "doc.richtext").font(.title).foregroundStyle(.tint)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(document.title).font(.headline).lineLimit(2)
                                            Text("\(document.position.page + 1) / \(document.pageCount) 페이지")
                                                .font(.subheadline).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 6)
                                }
                                .swipeActions {
                                    Button("삭제", role: .destructive) { pendingDelete = document }
                                }
                                .contextMenu { Button("문서 삭제", role: .destructive) { pendingDelete = document } }
                            }
                        }
                    }
                }
            }
            .navigationTitle("내 PDF")
            .navigationDestination(for: UUID.self) { id in
                if let repository = model.repository, let document = model.documents.first(where: { $0.id == id }) {
                    ReaderView(document: document, repository: repository, persistence: model.persistence)
                        .onDisappear { model.refresh() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.importing { ProgressView() }
                    else {
                        Button { showImporter = true } label: { Label("PDF 가져오기", systemImage: "plus") }
                            .disabled(model.repository == nil)
                    }
                }
            }
            .disabled(model.importing)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url): model.importPDF(url)
                case .failure(let error): model.error = error.localizedDescription
                }
            }
            .alert("문제가 발생했습니다", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("확인") { model.error = nil }
            } message: { Text(model.error ?? "") }
            .confirmationDialog("이 PDF와 그리기 기록을 삭제할까요?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    if let pendingDelete { model.delete(pendingDelete) }
                    pendingDelete = nil
                }
                Button("취소", role: .cancel) { pendingDelete = nil }
            } message: { Text("파일 앱의 원본 PDF는 유지됩니다.") }
        }
    }
}
