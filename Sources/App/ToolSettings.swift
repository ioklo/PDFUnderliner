import SwiftUI
import PencilKit

enum DrawingTool: String, Codable, CaseIterable {
    case pen, marker, eraser
    var title: String { switch self { case .pen: return "펜"; case .marker: return "형광펜"; case .eraser: return "획 지우개" } }
    var icon: String { switch self { case .pen: return "pencil.tip"; case .marker: return "highlighter"; case .eraser: return "eraser" } }
}

enum ReadingMode: String, CaseIterable {
    case continuous, paged
    var title: String { self == .continuous ? "세로 스크롤" : "한 페이지씩" }
}

struct StoredColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        red = r; green = g; blue = b
    }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    var color: Color { Color(uiColor: uiColor) }
}

struct ToolSettings: Codable, Equatable {
    var tool: DrawingTool = .pen
    var penColor = StoredColor(.black)
    var markerColor = StoredColor(.systemYellow)
    var penWidth = 1
    var markerWidth = 1

    var selectedColor: StoredColor {
        get { tool == .marker ? markerColor : penColor }
        set { if tool == .marker { markerColor = newValue } else { penColor = newValue } }
    }
    var widthIndex: Int {
        get { tool == .marker ? markerWidth : penWidth }
        set { if tool == .marker { markerWidth = newValue } else { penWidth = newValue } }
    }
    var pencilTool: PKTool {
        switch tool {
        case .eraser: return PKEraserTool(.vector)
        case .pen: return PKInkingTool(.pen, color: penColor.uiColor, width: [1.5, 3, 5][max(0, min(2, penWidth))])
        case .marker: return PKInkingTool(.marker, color: markerColor.uiColor.withAlphaComponent(0.35),
                                        width: [8, 14, 22][max(0, min(2, markerWidth))])
        }
    }

    static func load() -> ToolSettings {
        guard let data = UserDefaults.standard.data(forKey: "drawingTools"),
              let settings = try? JSONDecoder().decode(ToolSettings.self, from: data) else { return .init() }
        return settings
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "drawingTools") }
    }
}
