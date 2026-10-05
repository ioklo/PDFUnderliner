import SwiftUI

struct ReaderView: View {
    @StateObject private var session: ReaderSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showColors = false
    @State private var showWidths = false
    @State private var closing = false

    init(document: LibraryDocument, repository: DocumentRepository, persistence: DispatchQueue) {
        _session = StateObject(wrappedValue: ReaderSession(document: document, repository: repository, persistence: persistence))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = session.readOnlyReason {
                statusBanner(reason, symbol: "lock", retry: false)
            }
            if let error = session.saveError {
                statusBanner(error, symbol: "exclamationmark.triangle", retry: true)
            }
            ZStack {
                if session.pdf != nil { PDFReaderView(session: session) }
                if session.loading { ProgressView("PDF 여는 중…") }
                if let error = session.openError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error)
                    }.foregroundStyle(.secondary)
                }
            }
            if session.pdf != nil { drawingToolbar }
        }
        .navigationTitle(session.document.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { close() } label: { Label("문서 목록", systemImage: "chevron.left") }
                    .disabled(closing && session.isSaving)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Text("\(session.currentPage + 1) / \(session.document.pageCount)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(session.document.pageCount)페이지 중 \(session.currentPage + 1)페이지")
                    Menu {
                        Picker("읽기 방식", selection: $session.mode) {
                            ForEach(ReadingMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                        }
                    } label: { Image(systemName: session.mode == .continuous ? "arrow.up.arrow.down" : "book") }
                    .accessibilityLabel("읽기 방식")
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { session.flush(background: phase == .background) }
        }
        .onChange(of: session.isSaving) { saving in
            if closing && !saving {
                if session.saveError == nil && !session.hasUnsavedChanges { dismiss() }
                else { closing = false }
            }
        }
        .onDisappear { session.flush() }
    }

    private func close() {
        closing = true
        session.flush()
        if !session.isSaving {
            if !session.hasUnsavedChanges || session.openError != nil { dismiss() }
            else { closing = false }
        }
    }

    private func statusBanner(_ text: String, symbol: String, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if retry { Button("재시도") { session.retrySave() }.disabled(session.isSaving) }
        }
        .padding(12)
        .background(Color.orange.opacity(0.13))
    }

    private var drawingToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(DrawingTool.allCases, id: \.self) { tool in
                    Button { session.toolSettings.tool = tool } label: {
                        Image(systemName: tool.icon).font(.title3)
                            .frame(width: 44, height: 44)
                            .background(session.toolSettings.tool == tool ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(session.toolSettings.tool == tool ? .isSelected : [])
                }
                Divider().frame(height: 28)
                Button { showColors = true } label: {
                    Circle().fill(session.toolSettings.selectedColor.color)
                        .frame(width: 24, height: 24).overlay(Circle().stroke(.gray.opacity(0.5), lineWidth: 1))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("색상 선택")
                .disabled(session.toolSettings.tool == .eraser)
                .popover(isPresented: $showColors) { colorOptions }
                Button { showWidths = true } label: {
                    Image(systemName: "lineweight").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("굵기 선택")
                .disabled(session.toolSettings.tool == .eraser)
                .popover(isPresented: $showWidths) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("\(session.toolSettings.tool.title) 굵기").font(.headline)
                        Picker("굵기", selection: $session.toolSettings.widthIndex) {
                            Text("가는 선").tag(0)
                            Text("중간").tag(1)
                            Text("굵은 선").tag(2)
                        }.pickerStyle(.segmented)
                    }.padding().frame(width: 300)
                }
                Divider().frame(height: 28)
                Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }
                    .accessibilityLabel("실행 취소").disabled(!session.canUndo)
                Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }
                    .accessibilityLabel("다시 실행").disabled(!session.canRedo)
                if session.isSaving { ProgressView().frame(width: 24).accessibilityLabel("저장 중") }
            }.padding(.horizontal, 14).padding(.vertical, 6)
        }
        .background(.bar)
        .disabled(!session.writable)
    }

    private var colorOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(session.toolSettings.tool.title) 색상").font(.headline)
            HStack(spacing: 12) {
                ForEach(Array(palette.enumerated()), id: \.offset) { _, entry in
                    Button {
                        session.toolSettings.selectedColor = StoredColor(entry.color)
                    } label: {
                        Circle().fill(Color(uiColor: entry.color)).frame(width: 32, height: 32)
                            .overlay(Circle().stroke(.gray.opacity(0.5), lineWidth: 1))
                    }.accessibilityLabel(entry.name)
                }
            }
            ColorPicker("사용자 색상", selection: Binding(
                get: { session.toolSettings.selectedColor.color },
                set: { session.toolSettings.selectedColor = StoredColor(UIColor($0)) }
            ), supportsOpacity: false)
        }.padding(20).frame(width: 320)
    }

    private var palette: [(name: String, color: UIColor)] {
        [("검정", .black), ("빨강", .systemRed), ("파랑", .systemBlue),
         ("초록", .systemGreen), ("노랑", .systemYellow), ("보라", .systemPurple)]
    }
}
