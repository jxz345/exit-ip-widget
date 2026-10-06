// swift-tools-version: 6.0
import PackageDescription

// This package validates the shared, non-UI logic on macOS or Linux.
// The SwiftUI app and WidgetKit extension are assembled as Xcode targets; see README.md.
let package = Package(
    name: "ExitIPMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ExitIPShared", targets: ["ExitIPShared"])
    ],
    targets: [
        .target(
            name: "ExitIPShared",
            path: "Sources/ExitIPShared"
        ),
        .testTarget(
            name: "ExitIPSharedTests",
            dependencies: ["ExitIPShared"],
            path: "Tests/ExitIPSharedTests"
        )
    ]
)
