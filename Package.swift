// swift-tools-version:6.0
import PackageDescription

// Command Line Tools ship Testing.framework but SwiftPM does not put it on
// the test target's search path (and XCTest is absent without Xcode).
// ponytail: hardcoded CLT path; drop these unsafeFlags once Xcode is
// installed or a CLT release wires the path up itself.
let cltFrameworks =
    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltDevUsrLib =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "YierPet",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "YierPet",
            path: "Sources/YierPet",
            resources: [.copy("Resources/spritesheet.webp")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "YierPetTests",
            dependencies: ["YierPet"],
            path: "Tests/YierPetTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", cltFrameworks]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltDevUsrLib,
                ])
            ]
        ),
    ]
)
