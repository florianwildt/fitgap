// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FITgap",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "FITgapCore", targets: ["FITgapCore"]),
        .executable(name: "fitgap-probe", targets: ["FITgapProbe"]),
        .executable(name: "fitgap-wahoo-probe", targets: ["WahooProbe"])
    ],
    targets: [
        .target(name: "FITgapCore"),
        .executableTarget(name: "FITgapProbe", dependencies: ["FITgapCore"]),
        .executableTarget(name: "WahooProbe", dependencies: ["FITgapCore"]),
        .testTarget(name: "FITgapCoreTests", dependencies: ["FITgapCore"])
    ]
)
