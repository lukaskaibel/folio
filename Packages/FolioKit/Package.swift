// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FolioKit",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "FolioKit", targets: ["FolioKit"]),
    ],
    dependencies: [
        // Exact, as in Issues: its Mac images come out upside down and MermaidImage turns them round,
        // which a fix upstream would undo.
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift", exact: "1.0.4"),
        .package(url: "https://github.com/mgriebling/SwiftMath", from: "1.7.3"),
    ],
    targets: [
        .target(
            name: "FolioKit",
            dependencies: [
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FolioKitTests",
            dependencies: ["FolioKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
