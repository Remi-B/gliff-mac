// swift-tools-version: 6.0
import PackageDescription

// Run scripts/build-bridge.sh first: it produces the GliffCoreFFI XCFramework
// and the generated Swift bindings under Sources/GliffCore/Generated. Both are
// build outputs, ignored by Git.
let package = Package(
    name: "GliffCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GliffCore", targets: ["GliffCore"])],
    targets: [
        .binaryTarget(name: "GliffCoreFFI", path: "Artifacts/GliffCoreFFI.xcframework"),
        .target(
            name: "GliffCore",
            dependencies: ["GliffCoreFFI"],
            // The Rust standard library's native dependencies
            // (`cargo rustc --print native-static-libs`; libSystem is implicit).
            linkerSettings: [.linkedLibrary("iconv")]
        ),
        .testTarget(
            name: "GliffCoreTests",
            dependencies: ["GliffCore"]
        ),
    ]
)
