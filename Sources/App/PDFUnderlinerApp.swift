import SwiftUI

@main
struct PDFUnderlinerApp: App {
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup { LibraryView(model: library) }
    }
}
