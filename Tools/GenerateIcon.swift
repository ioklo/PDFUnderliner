import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Code-drawn app icon. Run from the repository root: swift Tools/GenerateIcon.swift
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
context.setFillColor(color(0.12, 0.23, 0.28))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setFillColor(color(0.98, 0.97, 0.93))
context.addPath(CGPath(roundedRect: CGRect(x: 218, y: 155, width: 590, height: 714),
                      cornerWidth: 36, cornerHeight: 36, transform: nil))
context.fillPath()
context.setStrokeColor(color(0.63, 0.67, 0.67))
context.setLineCap(.round)
context.setLineWidth(15)
for y in stride(from: 720, through: 340, by: -95) {
    context.move(to: CGPoint(x: 305, y: y))
    context.addLine(to: CGPoint(x: y == 340 ? 600 : 720, y: y))
    context.strokePath()
}
context.setStrokeColor(color(1, 0.79, 0.22, 0.6))
context.setLineWidth(52)
context.move(to: CGPoint(x: 290, y: 620))
context.addCurve(to: CGPoint(x: 744, y: 635), control1: CGPoint(x: 420, y: 600), control2: CGPoint(x: 610, y: 650))
context.strokePath()
context.setStrokeColor(color(0.13, 0.41, 0.58))
context.setLineWidth(17)
context.move(to: CGPoint(x: 288, y: 507))
context.addCurve(to: CGPoint(x: 751, y: 510), control1: CGPoint(x: 415, y: 480), control2: CGPoint(x: 614, y: 523))
context.strokePath()
let url = URL(fileURLWithPath: "Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon") }
