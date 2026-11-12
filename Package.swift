// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "HearNoteCore", targets: ["HearNoteCore"])]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(name: "HearNoteCore"),
    .testTarget(name: "HearNoteCoreTests", dependencies: ["HearNoteCore"])
]
#if os(macOS)
dependencies.append(.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"))
products.append(.executable(name: "HearNote", targets: ["HearNote"]))
targets.append(.executableTarget(name: "HearNote", dependencies: [
    "HearNoteCore", .product(name: "WhisperKit", package: "WhisperKit")
]))
#endif

let package = Package(name: "HearNote", platforms: [.macOS(.v14)], products: products,
                      dependencies: dependencies, targets: targets)
