// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "XMLTV",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "XMLTV", targets: ["XMLTV"]),
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "XMLTV", dependencies: ["CZlib"]),
        .executableTarget(
            name: "xmltv-bench",
            dependencies: ["XMLTV"],
            path: "Benchmarks/xmltv-bench"
        ),
        .testTarget(
            name: "XMLTVTests",
            dependencies: ["XMLTV"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
