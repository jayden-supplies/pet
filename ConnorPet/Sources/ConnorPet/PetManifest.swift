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

    /// 불뿜기 연출용 부가 정보. 불길은 스프라이트시트가 아니라 별도 창에
    /// 그려지므로(FlameWindow), 프레임마다 입이 어디인지와 불길이 얼마나
    /// 커졌는지를 앱이 알아야 한다. 이 행이 없는 펫에는 아예 없는 필드다.
    struct FireBreath: Codable {
        struct MouthFrame: Codable {
            let x: Double
            let y: Double
            let grow: Double
        }
        let mouthByFrame: [MouthFrame]
    }
    let fireBreath: FireBreath?

    static func load(from url: URL) throws -> PetManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PetManifest.self, from: data)
    }
}
