// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Axiom",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Axiom", targets: ["Axiom"])
    ],
    targets: [
        .executableTarget(
            name: "Axiom",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
