import Foundation

/// The light an entity gives off (`Entity.light`), from its middle, or a lamp where there's none (`Scene.lamps`): a
/// torch, a fireplace, a lantern or a glowing mushroom in a dark scene (`Scene.darkness`), a fireball's glow by day,
/// or, taking light away, a gloom. Where lights meet, they add up.
public struct Light: Sendable {
    /// How far it reaches, in pixels: it's brightest in the middle and fades to nothing there.
    public var radius: Double
    /// Its color, 0xRRGGBB: white, or a fire's orange. A darker color is a dimmer light. With `brightness` under 0 it's
    /// the light taken away: white takes all of it, as a gloom does, and a color takes only that color, so a blue one
    /// leaves the ground yellower.
    public var color: UInt32
    /// How much its radius wavers, from 0, steady, to 1: about 0.1 for a torch.
    public var flicker: Double
    /// How bright it is. At 1, the default, it lights the dark as far as daylight and no further, so by day it shows
    /// nothing; over 1 it lights past daylight, toward its own white, as a fireball or lightning does by day; under 0 it
    /// takes light away, as a gloom does.
    public var brightness: Double
    /// Where it shines from, in pixels from the entity's middle: a lantern held out in front, a torch on a wall. In an
    /// isometric scene, on the floor from the middle of the entity's footprint, where its light lies: what stands is lit
    /// by the floor under it, less of it the further up.
    public var offset: Vector
    /// How much of the world's color it drains around it, from 0 to 1, as much as it lights: a gloom's gray.
    public var gray: Double
    /// Whether it stops at what's opaque, casting shadows: a tileset's opaque tiles (its `.json`'s `opaque`) and opaque
    /// entities' hitboxes (`Entity.opaque`). Those it shines from inside don't stop it, so a lantern on a post still
    /// lights, nor does one a lit pixel is in, so a wall lights its own face.
    public var shadows: Bool
    /// An image whose brightness shapes it, instead of a round glow: stretched over its radius each way from its middle
    /// and turned by `angle`, a cone, a window's square, a gloom's swirl.
    public var image: ImageName?
    /// How far `image` is turned, in radians, clockwise.
    public var angle: Double
    var time = 0.0 // advanced by the scene's updates, so a paused game's flames stand still

    /// A light reaching `radius` pixels, white, steady and round unless you say otherwise: a torch is
    /// `Light(radius: 48, color: 0xFFAA55, flicker: 0.1)`, a gloom `Light(radius: 40, brightness: -1, gray: 1)`.
    public init(radius: Double, color: UInt32 = 0xFFFFFF, flicker: Double = 0, brightness: Double = 1, offset: Vector = .zero, gray: Double = 0,
                shadows: Bool = false, image: ImageName? = nil, angle: Double = 0) {
        (self.radius, self.color, self.flicker, self.brightness, self.offset) = (radius, color, flicker, brightness, offset)
        (self.gray, self.shadows, self.image, self.angle) = (gray, shadows, image, angle)
    }

    /// The radius now: smaller by up to `flicker` of it, wavering a few times a second. `seed` sets lights apart, so two
    /// torches don't flicker as one.
    func radius(seed: Int) -> Double {
        let phase = Double(seed % 1000)
        let wave = (sin(time * 13 + phase) + sin(time * 31 + phase * 2)) / 4 + 0.5 // 0 to 1, two waves that hardly repeat
        return radius * (1 - flicker * wave)
    }
}

/// Cloud shadows drifting over a scene (`Scene.clouds`): noise over the world, blown by the wind, that shades the
/// daylight but not the lights, so a fire under a cloud is as bright. Big, they're the shadows of clouds; small and
/// thick, the sun through leaves.
public struct Clouds: Sendable {
    /// How much of the sky they cover, from 0 to 1.
    public var cover: Double
    /// How much they darken the daylight under them, from 0 to 1.
    public var shade: Double
    /// About how big they are, in pixels.
    public var size: Double
    /// Where they drift, in pixels a second.
    public var wind: Vector
    /// Whether their edges are soft, shading between the game's pixels (the default), or dithered in the 4×4 pattern,
    /// each pixel in shade or not, as pixel art is. The light stays sharp either way.
    public var smooth: Bool

    /// Clouds covering `cover` of the sky, darkening the daylight under them by `shade`, about `size` pixels across and
    /// drifting with `wind`: by default a fair day's, `Clouds()`.
    public init(cover: Double = 0.45, shade: Double = 0.35, size: Double = 80, wind: Vector = [12, 5], smooth: Bool = true) {
        (self.cover, self.shade, self.size, self.wind, self.smooth) = (cover, shade, size, wind, smooth)
    }
}

/// Fog over a scene's world (`Scene.fog`), above its entities and under its overhangs: noise in a color, drifting with
/// the wind and churning, lit as the ground is, so a lantern lights it.
public struct Fog: Sendable {
    /// Its color, 0xRRGGBB.
    public var color: UInt32
    /// How thick it is where it's thickest, from 0 to 1.
    public var thickness: Double
    /// About how big its wisps are, in pixels.
    public var size: Double
    /// Where it drifts, in pixels a second.
    public var wind: Vector
    /// Whether it thins out softly, between the game's pixels (the default), or in dithered steps, as pixel art does.
    public var smooth: Bool

    /// Fog of `color`, `thickness` at its thickest, in wisps about `size` pixels across drifting with `wind`: by default
    /// a gray mist, `Fog()`.
    public init(color: UInt32 = 0x8C8FA6, thickness: Double = 0.5, size: Double = 48, wind: Vector = [6, 2], smooth: Bool = true) {
        (self.color, self.thickness, self.size, self.wind, self.smooth) = (color, thickness, size, wind, smooth)
    }
}

/// Where the light maps lie under a view whose top-left corner is at world pixel `view`: their first texel on the world
/// pixel that corner is in, and a texel more each way than the `game`'s size, for a view between pixels, and `below`
/// more down, for the floor under what stands below the view in an isometric picture and reaches up into it.
func lightMaps(under view: Vector, game: Size, below: Int = 0) -> (origin: Vector, size: Size) {
    (view.rounded(.down), Size(game.width + 1, game.height + 1 + below))
}

/// How far a light of `radius` reaches across and down the picture: as far both ways, or on an isometric floor, where
/// its round glow is an ellipse twice as wide as tall, √2 times as far across and half that down.
func reach(_ radius: Double, isometric: Bool) -> Vector { isometric ? [radius * 2.squareRoot(), radius / 2.squareRoot()] : [radius, radius] }

/// A light as it shines in a frame: from where, in world pixels, how far, as it flickers, and the rest of it.
struct Shine {
    var middle: Vector
    var radius: Double
    var light: Light
}

/// The light maps, a texel for each world pixel the view shows: the light with shadows, and in its alpha how gray
/// (`shadowed`); the light without them, and in its alpha the vignette (`open`); how thick the fog is; and how much
/// daylight the clouds leave, apart from the light, so they can be read between the game's pixels while it's sharp.
struct LightMaps {
    let shadowed, open, fog, clouds: GPUTexture
    let direction: GPUTexture // where the light at each texel comes from, for a scene that shapes its light (`Scene.shaping`)
}

/// The light maps' pipelines: a light added or taken away, the cap at daylight, the vignette multiplied, what's opaque
/// into the mask, the fog's thickness into its map, and the clouds into theirs.
struct LightStates {
    let add, take, cap, clouds, vignette, mask, fog: GPUPipeline
    /// The same for a scene that shapes its light, the direction map a third: only a light that adds light says where
    /// it comes from; one taking it away, the cap and the vignette leave the map alone.
    let shapedAdd, shapedTake, shapedCap, shapedVignette: GPUPipeline

    init(_ gpu: GPU) {
        let maps: [PixelFormat] = [.rgba16Float, .rgba16Float], shaped = maps + [.rgba16Float]
        add = gpu.pipeline("lightFragment", formats: maps, rgb: (.one, .one), alpha: (.one, .one))
        take = gpu.pipeline("lightFragment", formats: maps, rgb: (.one, .one), alpha: (.one, .one), operation: (.reverseSubtract, .add))
        cap = gpu.pipeline("capFragment", formats: maps, rgb: (.one, .one), alpha: (.one, .one), operation: (.min, .min))
        clouds = gpu.pipeline("cloudFragment", formats: [.r8], rgb: (.one, .zero), alpha: (.one, .zero))
        vignette = gpu.pipeline("vignetteFragment", formats: maps, rgb: (.destinationColor, .zero), alpha: (.destinationAlpha, .zero))
        mask = gpu.pipeline("maskFragment", formats: [.r8], rgb: (.one, .zero), alpha: (.one, .zero))
        fog = gpu.pipeline("fogNoiseFragment", formats: [.r8], rgb: (.one, .zero), alpha: (.one, .zero))
        shapedAdd = gpu.pipeline("shapedLightFragment", formats: shaped, rgb: (.one, .one), alpha: (.one, .one))
        shapedTake = gpu.pipeline("lightFragment", formats: shaped, rgb: (.one, .one), alpha: (.one, .one), operation: (.reverseSubtract, .add),
                                  masked: [2])
        shapedCap = gpu.pipeline("capFragment", formats: shaped, rgb: (.one, .one), alpha: (.one, .one), operation: (.min, .min), masked: [2])
        shapedVignette = gpu.pipeline("vignetteFragment", formats: shaped, rgb: (.destinationColor, .zero), alpha: (.destinationAlpha, .zero),
                                      masked: [2])
    }
}

extension Screen {
    /// Works out the light the scene's world is drawn in, before it's drawn, if anything lights it: darkness, clouds, fog,
    /// a vignette, gray, or a light that shows (any in the dark or under clouds; by day only one past daylight, taking
    /// light away or graying). It ends the canvas's pass if that's begun, draws what's opaque into the mask if a light
    /// that shows casts shadows, the clouds' map, the two light maps and the fog's, and with `shaping` the way to the
    /// lights, then goes on with the canvas, the maps bound for every quad to read as `lighting` says. The maps have a
    /// texel for each world pixel the view shows, from `offset` rounded down, so they stay on the ground as the camera
    /// moves between pixels, and cost the same at any `scale`.
    func light(_ scene: Scene, _ lights: [Shine], below: Int = 0) {
        (lit, pastDaylight) = (false, nil)
        let dark = min(max(scene.darkness, 0), 1)
        let dim = dark > 0 || scene.clouds != nil // so a light up to daylight shows
        let isometric = scene.projection == .isometric // its lights lie on the floor in the picture, and its standing things are lit from under them
        let (origin, size) = lightMaps(under: offset, game: self.size, below: below)
        let shown = lights.filter { shine in
            let (b, m, r) = (shine.light.brightness, shine.middle - origin, reach(shine.radius, isometric: isometric))
            return shine.radius > 0 && (dim || b > 1 || b < 0 || shine.light.gray > 0)
                && m.x + r.x > 0 && m.y + r.y > 0 && m.x - r.x < Double(size.width) && m.y - r.y < Double(size.height)
        }
        if shown.isEmpty { shaping = [] } // no light to turn toward, as by day: nothing's shaped, and that costs nothing
        guard dim || scene.gray > 0 || scene.clouds != nil || scene.fog != nil || scene.vignette > 0 || !shown.isEmpty else { return }
        pastDaylight = shown.filter { $0.light.brightness > 1 }.reduce(nil) { box, shine in // in the view's pixels
            let (m, r) = (shine.middle - offset, reach(shine.radius, isometric: isometric))
            let here = SIMD4<Float>(Float(m.x - r.x), Float(m.y - r.y), Float(m.x + r.x), Float(m.y + r.y))
            guard let box else { return here }
            return [min(box.x, here.x), min(box.y, here.y), max(box.z, here.z), max(box.w, here.w)]
        }
        interrupt()
        var canvas = current!
        let night = tint(scene.darknessColor), lit = 1 - Float(dark)
        let ambient = SIMD3<Float>(night.x, night.y, night.z) + (1 - SIMD3<Float>(night.x, night.y, night.z)) * lit
        view = makeView(origin: origin, maps: size, ambient: ambient, clouds: scene.clouds.map { $0.smooth ? 2 : 1 } ?? 0,
                        fog: scene.fog?.smooth == true, vignette: scene.vignette > 0)
        let maps = mapTextures(size), states = lightStates
        let whole: SIMD4<Float> = [0, 0, Float(size.width), Float(size.height)]

        // What's opaque, into the mask, as far around the view as the farthest shadowed light reaches.
        let shadowed = shown.filter(\.light.shadows)
        var margin = 0
        if let farthest = shadowed.map({ reach($0.radius, isometric: isometric).x }).max() {
            let mask = self.mask(size, margin: Int(farthest.rounded(.up)) + 1)
            margin = (mask.width - size.width) / 2
            go(Pass(targets: Targets([Target(texture: mask, load: .clear(red: 0, green: 0, blue: 0, alpha: 0))]), usual: states.mask,
                    size: Size(mask.width, mask.height)))
            let corner = origin - Double(margin) // the world pixel at the mask's first texel
            func opaque(_ box: Rect) {
                guard isometric else {
                    let (x, y) = (Float(Double(box.x) - corner.x), Float(Double(box.y) - corner.y))
                    return queue(white, [x, y, x + Float(box.width), y + Float(box.height)])
                }
                // On an isometric floor, its footprint as the picture shows it: a diamond, or for a long one a slanted box.
                let (x0, y0, x1, y1) = (Double(box.x), Double(box.y), Double(box.x + box.width), Double(box.y + box.height))
                queue(white, corners: [[x0, y0], [x1, y0], [x0, y1], [x1, y1]].map { (point: Vector) in
                    let at = Projection.isometric.picture(of: point) - corner
                    return SIMD2(Float(at.x), Float(at.y))
                })
            }
            if let map = scene.tilemap, !map.opaque.isEmpty, isometric {
                for (column, row) in map.isometricCells(left: corner.x, top: corner.y, right: corner.x + Double(mask.width), bottom: corner.y + Double(mask.height))
                where map.layers.contains(where: { $0[row * map.width + column].map(map.opaque.contains) ?? false }) {
                    opaque(Rect(x: column * map.tileSize, y: row * map.tileSize, width: map.tileSize, height: map.tileSize))
                }
            } else if let map = scene.tilemap, !map.opaque.isEmpty {
                let (left, top) = (Int(corner.x), Int(corner.y))
                for row in stride(from: max(map.cell(top), 0), through: min(map.cell(top + mask.height - 1), map.height - 1), by: 1) {
                    for column in stride(from: max(map.cell(left), 0), through: min(map.cell(left + mask.width - 1), map.width - 1), by: 1)
                    where map.layers.contains(where: { $0[row * map.width + column].map(map.opaque.contains) ?? false }) {
                        opaque(Rect(x: column * map.tileSize, y: row * map.tileSize, width: map.tileSize, height: map.tileSize))
                    }
                }
            }
            for entity in scene.entities where entity.opaque { opaque(entity.box(at: entity.drawnAt)) }
            end()
        }

        // How much daylight the clouds leave, first, for the cap at daylight to read.
        if let clouds = scene.clouds {
            go(Pass(targets: Targets([Target(texture: maps.clouds, load: .dontCare)]), usual: states.clouds, size: size))
            let blown = clouds.wind * time
            queue(white, whole, color: [Float(blown.x), Float(blown.y), Float(max(clouds.size, 1)), 0],
                  effects: [Float(clouds.cover), Float(clouds.shade), clouds.smooth ? 1 : 0, 0])
            end()
        }

        // The light maps: the ambient; lights added, capped at daylight; then lights past it added and those under 0
        // taken away; then the vignette.
        let pass = Targets([maps.shadowed, maps.open].enumerated().map { i, texture in
            let gray = i == 0 ? min(max(scene.gray, 0), 1) : 1 // and the open one's vignette
            return Target(texture: texture, load: .clear(red: Double(ambient.x), green: Double(ambient.y), blue: Double(ambient.z), alpha: gray))
        })
        let shaping = !self.shaping.isEmpty // and where the light comes from, which it shows
        if shaping { pass.colors.append(Target(texture: maps.direction, load: .clear(red: 0, green: 0, blue: 0, alpha: 0))) }
        let (add, take, cap, vignette) = shaping ? (states.shapedAdd, states.shapedTake, states.shapedCap, states.shapedVignette)
                                                 : (states.add, states.take, states.cap, states.vignette)
        go(Pass(targets: pass, usual: add, size: size, textures: [mask ?? white]))
        func glow(_ shine: Shine, _ much: Double, gray: Double, state: GPUPipeline? = nil) {
            let (m, r, light) = (shine.middle - origin, shine.radius, shine.light)
            let color = tint(light.color) * Float(much), far = reach(r, isometric: isometric)
            queue(light.image.map { texture($0.name) } ?? white,
                  [Float((m.x - far.x).rounded(.down)), Float((m.y - far.y).rounded(.down)), Float((m.x + far.x).rounded(.up)), Float((m.y + far.y).rounded(.up))],
                  color: [color.x, color.y, color.z, Float(min(max(gray, 0), 1))], effects: [Float(m.x), Float(m.y), Float(r), light.shadows ? 1 : 0],
                  more: [Float(light.angle), light.image == nil ? 0 : 1, Float(margin), isometric ? 1 : 0], state: state)
        }
        for shine in shown where shine.light.brightness > 0 { glow(shine, min(shine.light.brightness, 1), gray: shine.light.gray) }
        queue(scene.clouds == nil ? white : maps.clouds, whole, state: cap)
        for shine in shown where shine.light.brightness > 1 { glow(shine, shine.light.brightness - 1, gray: 0) }
        for shine in shown where shine.light.brightness <= 0 { glow(shine, -shine.light.brightness, gray: shine.light.gray, state: take) }
        if scene.vignette > 0 { queue(white, whole, effects: [Float(min(scene.vignette, 1)), 0, 0, 0], state: vignette) }
        end()

        // How thick the fog is.
        if let fog = scene.fog {
            go(Pass(targets: Targets([Target(texture: maps.fog, load: .dontCare)]), usual: states.fog, size: size))
            let blown = fog.wind * time
            queue(white, whole, color: [Float(blown.x), Float(blown.y), Float(max(fog.size, 1)), 0],
                  effects: [Float(fog.thickness), Float(time * 0.05), fog.smooth ? 1 : 0, 0])
            end()
        }

        canvas.textures = [maps.shadowed, maps.open, scene.clouds == nil ? white : maps.clouds, shaping ? maps.direction : white]
        go(canvas)
        self.lit = true
    }

    /// Draws the scene's fog over the world, from its map, lit as the ground is.
    func draw(_ fog: Fog) {
        guard lit, let maps else { return }
        queue(maps.fog, [0, 0, Float(size.width), Float(size.height)], color: tint(fog.color), state: fogged)
    }

    /// The light maps, `size` texels, made the first time a scene is lit.
    func mapTextures(_ size: Size) -> LightMaps {
        if let maps, maps.open.width == size.width, maps.open.height == size.height { return maps }
        func texture(_ format: PixelFormat) -> GPUTexture { gpu.texture(format, width: size.width, height: size.height) }
        maps = LightMaps(shadowed: texture(.rgba16Float), open: texture(.rgba16Float), fog: texture(.r8), clouds: texture(.r8),
                         direction: texture(.rgba16Float))
        return maps!
    }

    /// The mask of what's opaque: the light maps' `size` and at least `margin` more each way, made again only when it
    /// has to grow.
    func mask(_ size: Size, margin: Int) -> GPUTexture {
        if let mask, mask.width >= size.width + 2 * margin, mask.height - size.height == mask.width - size.width { return mask }
        let margin = (margin + 31) / 32 * 32 // so a flickering light doesn't make it again every frame
        mask = gpu.texture(.r8, width: size.width + 2 * margin, height: size.height + 2 * margin)
        return mask!
    }
}
