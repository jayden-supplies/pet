// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "ConnorPet",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "ConnorPet",
            resources: [
                .copy("Resources/spritesheet.png"),
                .copy("Resources/pet.json")
            ]
        )
    ]
)
