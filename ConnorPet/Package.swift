// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "ConnorPet",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ConnorPet",
            resources: [
                .copy("Resources/pets")
            ],
            // NotificationCenterDB reads macOS's Notification Center SQLite DB.
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "ConnorPetTests",
            dependencies: ["ConnorPet"]
        ),
    ]
)
