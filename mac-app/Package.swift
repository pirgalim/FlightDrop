// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FlightDropMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FlightDropMac", targets: ["FlightDropMac"])
    ],
    targets: [
        .executableTarget(
            name: "FlightDropMac",
            path: "Sources/FlightDropMac"
        )
    ]
)
