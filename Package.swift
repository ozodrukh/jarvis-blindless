// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    products: [.library(name: "JarvisCore", targets: ["JarvisCore"]), .executable(name: "Jarvis", targets: ["Jarvis"])],
    targets: [
        .target(name: "JarvisCore"),
        .executableTarget(name: "Jarvis", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
        .testTarget(name: "JarvisAppTests", dependencies: ["Jarvis", "JarvisCore"])
    ]
)
