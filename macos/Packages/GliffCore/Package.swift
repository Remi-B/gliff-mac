// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GliffCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "GliffCore", targets: ["GliffCore"])],
    targets: [.target(name: "GliffCore")]
)
