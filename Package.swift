// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFUnderlinerCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "PDFUnderlinerCore", targets: ["PDFUnderlinerCore"])],
    targets: [
        .target(name: "PDFUnderlinerCore", path: "Sources/Core"),
        .testTarget(name: "PDFUnderlinerCoreTests", dependencies: ["PDFUnderlinerCore"], path: "Tests/CoreTests")
    ]
)
