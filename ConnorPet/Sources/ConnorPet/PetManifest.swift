import Foundation

/// Mirrors Orca's `pet.json` manifest shape (`pet-bundle-manifest-schema.ts`).
struct PetManifest: Codable {
    struct Frame: Codable {
        let width: Int
        let height: Int
    }
    struct Animation: Codable {
        let row: Int
        let frames: Int
        let frameDurationsMs: [Double]?
    }

    let id: String?
    let displayName: String?
    let description: String?
    let spritesheetPath: String?
    let frame: Frame
    let fps: Double
    let defaultAnimation: String?
    let animations: [String: Animation]

    static func load(from url: URL) throws -> PetManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PetManifest.self, from: data)
    }
}
