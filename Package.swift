// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EducationOSPDFReader",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "EducationOSPDFReader", targets: ["EducationOSPDFReader"])
    ],
    targets: [
        .executableTarget(
            name: "EducationOSPDFReader",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
