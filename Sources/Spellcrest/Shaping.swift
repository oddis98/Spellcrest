import Foundation

/// How a scene's lit sprites and tiles show which side their light is on (`Scene.shaping`): a torch lighting a
/// pillar's face toward it and leaving the far side dark. Only lights do, not daylight, so a scene by day looks as it
/// did. None, the default, leaves the light as it was.
public struct Shaping: OptionSet, Sendable {
    /// The ways as bits: 1 normal maps, 2 a rim.
    public let rawValue: Int
    /// The ways `rawValue`'s bits say, which `normals` and `rim` name.
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Images with a normal map beside them, `<image>.normal.png`, are lit by it: each of their pixels brighter where it
    /// faces the light and darker where it faces away. A normal map's red is right, green down, as y is on the screen,
    /// and blue out of the screen; one made with green up, as Laigter makes them unless y is inverted, is lit upside down.
    public static let normals = Shaping(rawValue: 1)
    /// Sprites without a normal map catch a rim of light on their edges that face it.
    public static let rim = Shaping(rawValue: 2)
}

/// A light where there's no entity (`Scene.lamps`): a torch on a wall, a lantern on a post, a flash where a spell
/// lands. Tiles can give them too, by their tileset's properties (`Tilemap.lamps`).
public struct Lamp: Sendable {
    /// Where it is, in world pixels: its light shines from there, moved by its `offset`. In an isometric scene, a point on
    /// the floor, where its light lies.
    public var position: Vector
    /// Its light.
    public var light: Light

    /// `light` shining from `position`, in world pixels.
    public init(at position: Vector, light: Light) { (self.position, self.light) = (position, light) }
}

extension Tilemap {
    /// The light a tile gives by its tileset's properties, set in the map editor's tile panel: `light`, how far it
    /// reaches in pixels, which lights it; `lightColor`, `lightFlicker`, `lightBrightness` and `lightShadows` as a
    /// `Light`'s, white, steady, 1 and without shadows unless they say. Nil for a tile that doesn't light.
    func light(of tile: Int) -> Light? {
        let properties = TileProperties(properties: sheet?.properties(of: tile) ?? [:])
        guard let radius = properties.double("light"), radius > 0 else { return nil }
        return Light(radius: radius, color: properties.color("lightColor") ?? 0xFFFFFF, flicker: properties.double("lightFlicker") ?? 0,
                     brightness: properties.double("lightBrightness") ?? 1, shadows: properties.bool("lightShadows"))
    }

    /// Finds the lights its tiles give, at each one's middle, once a map and again as its tiles change.
    mutating func findLamps() {
        var lights: [Int: Light?] = [:] // each tile's, asked once
        lamps = []
        for layer in layers {
            for (i, cell) in layer.enumerated() {
                guard let tile = cell else { continue }
                if lights[tile] == nil { lights[tile] = .some(light(of: tile)) }
                guard let light = lights[tile] ?? nil else { continue }
                let (column, row) = (i % width, i / width)
                lamps.append(Lamp(at: [Double(column * tileSize) + Double(tileSize) / 2, Double(row * tileSize) + Double(tileSize) / 2], light: light))
            }
        }
    }
}

extension Screen {
    /// `<image>.normal.png`, the normal map beside an image, for light that shapes it; nil without one. It's looked for
    /// the first time it's asked for, and where files can change, loaded once it's there (`reloadChangedAssets`).
    func normalMap(_ image: String) -> GPUTexture? {
        let name = "\(image).normal"
        if let texture = textures[name] { return texture === clear ? nil : texture }
        let url = assetURL("\(name).png"), date = modificationDate(url)
        modified["\(name).png"] = date
        guard date != nil, let texture = try? self.image(url) else {
            textures[name] = clear // none: lit as before
            return nil
        }
        textures[name] = texture
        return texture
    }
}
