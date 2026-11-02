import ImageIO
import MetalKit
import SpellcrestProtocol
import Synchronization

/// The pixel canvas your game draws on. (0, 0) is the top-left pixel.
@MainActor public final class Screen {
    /// The canvas's size in pixels, the game's `resolution`: for laying out a HUD.
    public let size: Size
    let device: MTLDevice
    let library: MTLLibrary // the engine's shaders
    let pipeline: MTLRenderPipelineState // sprites, blended by their alpha, lit as `lighting` says
    let glowing: MTLRenderPipelineState // sprites that glow (`Sprite.glows`), added to what's under them, unlit
    let smooth: MTLRenderPipelineState // the canvas on the screen, scaled the last little way with linear filtering
    let parallax: MTLRenderPipelineState // backdrops and overhangs, their images repeated and swaying
    let fogged: MTLRenderPipelineState // fog over the world, as thick as its map says
    /// The light maps' pipelines, made in the background as the screen is, so a game's first lit frame, at dusk, say,
    /// doesn't wait for them; or then, if it comes first.
    var lightStates: LightStates {
        if made == nil { made = LightStates(library, device) }
        return made!
    }
    private var made: LightStates?
    /// The particles' pipelines, made in the background as the light maps' are.
    var particleStates: ParticleStates {
        if madeParticles == nil { madeParticles = ParticleStates(library, format: canvasDescriptor.pixelFormat) }
        return madeParticles!
    }
    private var madeParticles: ParticleStates?
    /// The bloom's and the bends' pipelines, made in the background as the light maps' are.
    var glowStates: GlowStates {
        if madeGlow == nil { madeGlow = GlowStates(library, format: canvasDescriptor.pixelFormat) }
        return madeGlow!
    }
    private var madeGlow: GlowStates?
    /// While a scene with a bloom draws its world (`blooming`), the glowing quads it queues, which the bloom draws again;
    /// where in the view light past daylight shows, which blooms too, nil where none does; and the bloom's two maps and
    /// the bends' map.
    var blooming = false, glowed: [Glowed] = [], pastDaylight: SIMD4<Float>?
    var bloomMap: MTLTexture?, bloomSpare: MTLTexture?, bendMap: MTLTexture?
    /// How many times the game's size the canvas is drawn at, a whole number: at 1 everything is on the game's whole
    /// pixels, at k on k-ths of them, so what moves between them is drawn where it is (`GameView` sets it for the screen).
    private(set) var scale = 1
    private(set) var canvas: MTLTexture
    let canvasDescriptor: MTLTextureDescriptor
    /// The last frame before a dissolve, which it draws over the next scene, and a second canvas that a game's effects
    /// draw into from the first (`apply`): the canvas's size, made again when it changes.
    var snapshot: MTLTexture {
        get { canvasSized(&lastFrame) }
        set { lastFrame = newValue }
    }
    var spare: MTLTexture { canvasSized(&other) }
    private var lastFrame: MTLTexture?, other: MTLTexture?
    /// How far the frame is from the last update to the next, from 0 to 1, for where entities are drawn (`Entity.drawnAt`).
    var alpha = 1.0
    /// The scene's time in seconds, between updates as the entities are, for what moves: clouds, fog, swaying, shaders.
    var time = 0.0
    let loader: MTKTextureLoader
    var textures: [String: MTLTexture] = [:]
    var sheets: [String: SheetFile?] = [:] // nil: the image has no .json, so it's a single frame
    var fonts: [String: Font] = [:] // image fonts, measured on first use
    var modified: [String: Date?] = [:] // each loaded file's modification date, to spot edits
    var wearing: [String: Set<String>] = [:] // the people made of each part, and of the kit, by their images' names
    var warned: Set<String> = []
    var commands: MTLCommandBuffer!
    /// The pass quads go to now: the canvas's, a light map's, or the drawable's.
    private(set) var current: Pass!
    private var open: MTLRenderCommandEncoder? // its encoder, begun as the first quad reaches it
    var drawing: MTLRenderPipelineState? // the pipeline `open` draws with, which particles' draws set too
    /// The pass's encoder, begun now if it hasn't been: a pass begun but never drawn in still clears.
    var encoder: MTLRenderCommandEncoder { open ?? opened() }
    // Queued quads, all with `batch`'s texture, pipeline and values, five for each corner: x, y, u, v; the tint r, g, b,
    // a; and what the fragments make of it (`Corner` in the shaders).
    var vertices: [SIMD4<Float>] = []
    var batch: (texture: MTLTexture, state: MTLRenderPipelineState, values: [Float]?, normals: MTLTexture?)?
    /// How the scene being drawn shapes its light, which lit sprites and tiles show (`Scene.shaping`).
    var shaping: Shaping = []
    /// The built-in font's glyphs, made on first use.
    lazy var builtInFont = Font.builtInTexture(device)
    /// One white pixel, which `fill` stretches and tints.
    lazy var white: MTLTexture = pixel(UInt32.max)
    /// One clear pixel, which a missing image draws as.
    lazy var clear: MTLTexture = pixel(0)
    /// The images that are missing or can't be read, drawn as `clear`.
    var missing: Set<String> = []

    private func pixel(_ rgba: UInt32) -> MTLTexture {
        let texture = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false))!
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [rgba], bytesPerRow: 4)
        return texture
    }
    /// Subtracted from every position; the scene sets it to its camera.
    var offset = Vector.zero
    /// How what's drawn now is lit by the scene's light maps, and where it stands, for `.standing`, in world pixels.
    var lighting = Lighting.none
    var feet = Vector.zero
    /// Where what's drawn now stands in an isometric picture, for `.raised`: its footprint's front edges, x1 and y1, and
    /// its height, in world pixels.
    var stand = SIMD4<Float>.zero
    /// Whether the scene being drawn has light maps this frame (`light`), and the `View` the shaders read.
    var lit = false
    var view: [Float] = []
    /// The light maps, made the first time a scene is lit, and what's opaque, grown to the shadows' margin as needed.
    var maps: LightMaps?
    var mask: MTLTexture?
    /// The game's own shaders, by name and kind, as they compile (Shader.swift).
    var shaders: [ShaderKey: Compiled] = [:]

    init(size: Size, device: MTLDevice, format: MTLPixelFormat) {
        self.size = size
        self.device = device
        loader = MTKTextureLoader(device: device)

        let library: MTLLibrary
        do { library = try device.makeLibrary(source: shaderCommon + shapingShaders + shaderEngine + lightShaders + particleShaders + glowShaders, options: nil) } catch {
            fatalError("Spellcrest: its shaders don't compile: \(error)")
        }
        self.library = library
        func state(_ fragment: String, rgb: (MTLBlendFactor, MTLBlendFactor), alpha: (MTLBlendFactor, MTLBlendFactor)) -> MTLRenderPipelineState {
            makeState(library, fragment, formats: [format], rgb: rgb, alpha: alpha)
        }
        pipeline = makeState(library, "spriteFragment", vertex: "litVertex", formats: [format], rgb: (.sourceAlpha, .oneMinusSourceAlpha),
                             alpha: (.one, .oneMinusSourceAlpha))
        glowing = state("glowFragment", rgb: (.one, .one), alpha: (.zero, .one))
        smooth = state("smoothFragment", rgb: (.one, .zero), alpha: (.one, .zero))
        parallax = state("parallaxFragment", rgb: (.sourceAlpha, .oneMinusSourceAlpha), alpha: (.one, .oneMinusSourceAlpha))
        fogged = state("fogFragment", rgb: (.sourceAlpha, .oneMinusSourceAlpha), alpha: (.zero, .one))

        let texture = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: size.width, height: size.height, mipmapped: false)
        texture.usage = [.renderTarget, .shaderRead]
        texture.storageMode = .private
        (canvasDescriptor, canvas) = (texture, device.makeTexture(descriptor: texture)!)
        let handed = Handed(value: (library, device))
        DispatchQueue.global(qos: .userInitiated).async {
            let states = Handed(value: (LightStates(handed.value.0, handed.value.1), ParticleStates(handed.value.0, format: format),
                                        GlowStates(handed.value.0, format: format)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if self.made == nil { self.made = states.value.0 }
                    if self.madeParticles == nil { self.madeParticles = states.value.1 }
                    if self.madeGlow == nil { self.madeGlow = states.value.2 }
                }
            }
        }
    }

    /// Draws the canvas at `scale` times the game's size from the next frame on.
    func resize(to scale: Int) {
        guard scale != self.scale else { return }
        self.scale = scale
        (canvasDescriptor.width, canvasDescriptor.height) = (size.width * scale, size.height * scale)
        canvas = device.makeTexture(descriptor: canvasDescriptor)!
        (lastFrame, other) = (nil, nil)
    }

    /// Makes the spare the canvas and the canvas the spare, once an effect has drawn the picture into the spare.
    func turnOver() { (canvas, other) = (spare, canvas) }

    private func canvasSized(_ texture: inout MTLTexture?) -> MTLTexture {
        if texture == nil { texture = device.makeTexture(descriptor: canvasDescriptor)! }
        return texture!
    }

    /// Draws all of `Assets/<image>.png` with its top-left corner at (x, y), each of its pixels `scale` pixels square:
    /// 3 for a title three times the size it's drawn. Where the canvas is drawn bigger than the game, as it is on most
    /// screens, x and y go to the nearest part of a pixel below them, so what moves between pixels moves smoothly; give
    /// whole numbers to keep it on the game's pixels.
    public func draw(_ image: ImageName, x: Double, y: Double, scale: Int = 1) { draw(image.name, x: x, y: y, scale: scale) }

    /// Draws an image named in a string.
    @_disfavoredOverload public func draw(_ image: String, x: Double, y: Double, scale: Int = 1) {
        let texture = texture(image)
        quad(texture, x: x, y: y, source: Rect(x: 0, y: 0, width: texture.width, height: texture.height),
             size: Size(texture.width * scale, texture.height * scale))
    }

    /// Draws the sprite's current frame with its top-left corner at (x, y), as `draw(_:x:y:scale:)` draws an image:
    /// added to what's under it if it `glows`, and through its `shader` once that's compiled.
    public func draw(_ sprite: Sprite, x: Double, y: Double, scale: Int = 1) {
        let texture = texture(sprite.image)
        var frame = 0, flipped = sprite.flipped
        if let name = sprite.animation {
            let animations = sheet(sprite.image)?.animations
            var playing = name // or, facing a way, the animation for it, or for the way it mirrors
            if let facing = sprite.facing, let animations {
                if animations["\(name)-\(facing.rawValue)"] != nil { playing = "\(name)-\(facing.rawValue)" }
                else if animations["\(name)-\(facing.mirrored.rawValue)"] != nil { (playing, flipped) = ("\(name)-\(facing.mirrored.rawValue)", !flipped) }
            }
            if let shown = animations?[playing]?.frame(at: sprite.time) {
                frame = shown
            } else if warned.insert("\(sprite.image) \(name)").inserted {
                print("Spellcrest: \(sprite.image).json has no animation \"\(name)\"")
            }
        }
        let source = region(frame, self.frame(sprite.image), in: texture)
        var state = sprite.glows ? glowing : nil, values: [Float]?
        if let shader = sprite.shader, let made = self.shader(shader.name.name, .color) {
            (state, values) = (sprite.glows ? made.glowing : made.state, self.values(shader))
        }
        // Lit and shaping its light: turned toward it by its normal map if it has one, or else by a rim on its edges.
        let shaped = !shaping.isEmpty && lighting != .none && !sprite.glows && sprite.shader == nil
        let normals = shaped && shaping.contains(.normals) ? normalMap(sprite.image) : nil, rim = shaped && normals == nil && shaping.contains(.rim)
        quad(texture, x: x, y: y, source: source, size: Size(source.width * scale, source.height * scale), flip: flipped,
             color: sprite.color, opacity: sprite.opacity, flash: sprite.flash, glows: sprite.glows, state: state, values: values,
             frame: rim ? [Float(source.width), Float(source.height)] : [Float(source.x), Float(source.y)], normals: normals, rim: rim)
    }

    /// The size of one of the game's images: a frame's, if its `.json` cuts it into frames, else the whole image's;
    /// nil when there's none. To lay out what's drawn with it: `x: Double(160 - screen.size(of: .title)!.width / 2)`.
    public func size(of image: ImageName) -> Size? { size(of: image.name) }

    /// The size of an image named in a string.
    @_disfavoredOverload public func size(of image: String) -> Size? {
        _ = texture(image)
        return missing.contains(image) ? nil : frame(image)
    }

    /// Draws the tilemap's `layers` (all of them unless you say), first to last: only the tiles on the canvas, so
    /// levels can be many screens big. `Scene` draws its `tilemap` this way, the layers `above` after the entities.
    public func draw(_ map: Tilemap, layers: [Int]? = nil) {
        let texture = texture(map.tileset)
        let normals = shaping.contains(.normals) && lighting != .none ? normalMap(map.tileset) : nil // its tileset's, when it shapes its light
        let tile = Size(map.tileSize, map.tileSize)
        let frames = map.frames(sheet(map.tileset)?.animations)
        guard map.projection == .flat else { return drawIsometric(map, layers: layers ?? Array(map.layers.indices), texture: texture, frames: frames, normals: normals) }
        // The world pixels the canvas shows any of, the camera on them or between them.
        let (left, top) = (Int(offset.x.rounded(.down)), Int(offset.y.rounded(.down)))
        let (right, bottom) = (Int((offset.x + Double(size.width)).rounded(.up)) - 1, Int((offset.y + Double(size.height)).rounded(.up)) - 1)
        let columns = stride(from: max(map.cell(left), 0), through: min(map.cell(right), map.width - 1), by: 1)
        let rows = stride(from: max(map.cell(top), 0), through: min(map.cell(bottom), map.height - 1), by: 1)
        for layer in layers ?? Array(map.layers.indices) where map.layers.indices.contains(layer) {
            for row in rows {
                for column in columns {
                    guard let cell = map.layers[layer][row * map.width + column] else { continue }
                    quad(texture, x: Double(column * map.tileSize), y: Double(row * map.tileSize), source: region(frames[cell] ?? cell, tile, in: texture),
                         normals: normals)
                }
            }
        }
    }

    /// Draws an isometric map's layers as the floor: each cell's tile a frame of its tileset, twice as wide as the cell,
    /// its bottom on the bottom of the cell's diamond, so a frame taller than the diamond reaches up above it. Cells go
    /// from the back of the view to its front, only those whose frames show any of it.
    func drawIsometric(_ map: Tilemap, layers: [Int], texture: MTLTexture, frames: [Int: Int], normals: MTLTexture?) {
        let cell = Double(map.tileSize)
        let frame = sheet(map.tileset).map { Size($0.frameWidth, $0.frameHeight) } ?? Size(map.tileSize * 2, map.tileSize)
        let cells = map.isometricCells(left: offset.x, top: offset.y, right: offset.x + Double(size.width), bottom: offset.y + Double(size.height), frame: frame)
        for layer in layers where map.layers.indices.contains(layer) {
            for (column, row) in cells {
                guard let tile = map.layers[layer][row * map.width + column] else { continue }
                quad(texture, x: Double(column - row) * cell - Double(frame.width) / 2, y: Double(column + row + 2) * cell / 2 - Double(frame.height),
                     source: region(frames[tile] ?? tile, frame, in: texture), normals: normals)
            }
        }
    }

    /// Fills `box` with a color, 0xRRGGBB, at an `opacity` from 0 to 1: a health bar, a text box's back, or a night
    /// that darkens the world.
    public func fill(_ box: Rect, color: UInt32, opacity: Double = 1) {
        quad(white, x: Double(box.x), y: Double(box.y), source: Rect(x: 0, y: 0, width: 1, height: 1),
             size: Size(box.width, box.height), color: color, opacity: opacity)
    }

    /// Draws `Assets/<image>.png` (its first frame, if its `.json` cuts it up) as a box of any size: the image cut
    /// in thirds each way, its corners as they are, its edges stretched along their length and its middle both ways.
    /// One frame drawn in the pixel editor makes every text box and menu.
    public func panel(_ image: ImageName, in box: Rect) { panel(image.name, in: box) }

    /// Draws an image named in a string as a box.
    @_disfavoredOverload public func panel(_ image: String, in box: Rect) {
        let (texture, frame) = (texture(image), frame(image))
        // Each third's start and length, in the image and in the box. In a box smaller than two corners, they overlap.
        func thirds(_ image: Int, _ start: Int, _ length: Int) -> [(from: Int, length: Int, to: Int, size: Int)] {
            let corner = image / 3
            return [(0, corner, start, corner), (corner, image - corner * 2, start + corner, max(0, length - corner * 2)),
                    (image - corner, corner, start + length - corner, corner)]
        }
        for row in thirds(frame.height, box.y, box.height) {
            for column in thirds(frame.width, box.x, box.width) where row.size > 0 && column.size > 0 {
                quad(texture, x: Double(column.to), y: Double(row.to), source: Rect(x: column.from, y: row.from, width: column.length, height: row.length),
                     size: Size(column.size, row.size))
            }
        }
    }

    /// The size of an image's frames, as its `.json` cuts it up, or of the whole image.
    func frame(_ image: String) -> Size {
        sheet(image).map { Size($0.frameWidth, $0.frameHeight) } ?? Size(texture(image).width, texture(image).height)
    }

    /// The middle of an entity where it's drawn, in world pixels: of its sprite's frame, or of its hitbox without one.
    /// Its light shines from there, and an iris closes on it.
    func middle(of entity: Entity) -> Vector {
        let corner = entity.drawnAt
        guard let sprite = entity.sprite else {
            let box = entity.hitbox
            return corner + [Double(box.x), Double(box.y)] + [Double(box.width), Double(box.height)] / 2
        }
        let frame = frame(sprite.image)
        return corner + [Double(frame.width), Double(frame.height)] / 2
    }

    /// Queues a texture the canvas's size over all of it, with no camera: the snapshot, the canvas itself.
    func whole(_ texture: MTLTexture, keep: Double = 1) {
        quad(texture, x: 0, y: 0, source: Rect(x: 0, y: 0, width: texture.width, height: texture.height), size: size, keep: keep)
    }

    /// Copies the canvas as it is, still the last frame, for a dissolve to draw over the next scene.
    func snap(_ commands: MTLCommandBuffer) {
        guard let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: canvas, to: snapshot)
        blit.endEncoding()
    }

    /// The `index`th `size` region of a sheet, counting left to right, then top to bottom.
    func region(_ index: Int, _ size: Size, in texture: MTLTexture) -> Rect {
        let columns = max(1, texture.width / size.width)
        return Rect(x: index % columns * size.width, y: index / columns * size.height, width: size.width, height: size.height)
    }

    /// The image `name`, loaded the first time it's drawn. One that's missing or can't be read draws nothing, and the
    /// console says why, once, so the game goes on; where files can change, it's loaded once its file is there.
    func texture(_ name: String) -> MTLTexture {
        if let texture = textures[name] { return texture }
        if name.hasPrefix(Person.prefix) { return personTexture(name) }
        let url = assetURL("\(name).png")
        modified["\(name).png"] = modificationDate(url)
        do {
            let texture = try loader.newTexture(URL: url, options: [.SRGB: false])
            textures[name] = texture
            return texture
        } catch {
            if warned.insert("\(name).png").inserted { print("Spellcrest: can't load \(url.path), so it draws nothing: \(error.localizedDescription)") }
            missing.insert(name)
            textures[name] = clear
            return clear
        }
    }

    /// How an image is cut into frames, from its `.json`; nil if it has none.
    func sheet(_ name: String) -> SheetFile? {
        if let sheet = sheets[name] { return sheet }
        if name.hasPrefix(Person.prefix) { return madePerson(name)?.sheet }
        let url = assetURL("\(name).json")
        var sheet: SheetFile?
        if FileManager.default.fileExists(atPath: url.path) {
            do { sheet = try SheetFile(contentsOf: url) } catch { print("Spellcrest: can't read \(url.path): \(error.localizedDescription)") }
        }
        sheets[name] = .some(sheet)
        modified["\(name).json"] = modificationDate(url)
        return sheet
    }

    /// Reloads images and their `.json` files that changed on disk, e.g. saved by the editor.
    /// An image that can't be read (deleted, half-written) keeps its old texture.
    func reloadChangedAssets() {
        for (file, date) in modified {
            let url = assetURL(file)
            guard modificationDate(url) != date else { continue }
            modified[file] = modificationDate(url)
            if file.hasPrefix("Parts/") { // a part, or the kit: the people made of it are made again
                remakePeople(wearing: file)
                continue
            }
            let name = (file as NSString).deletingPathExtension
            if file.hasSuffix(".json") {
                (sheets[name], fonts[name]) = (nil, nil) // read again on next use
            } else if let texture = try? loader.newTexture(URL: url, options: [.SRGB: false]) {
                (textures[name], fonts[name]) = (texture, nil)
                missing.remove(name)
            }
        }
    }

    /// Queues a textured quad: `source`, from the texture, stretched over `size` (the same size unless you say), its
    /// pixels multiplied by `color` (0xRRGGBB, where white leaves them as they are) and `opacity`, then mixed toward
    /// white by `flash`; of a dissolve's 4x4 pattern, only the share `keep` of its pixels draw. It's lit as `lighting`
    /// says, unless it `glows`, through `state` with `values` (a game's shader), or the pass's usual pipeline. `frame` is
    /// where a sprite's frame is in the texture, for a shader's positions, or with a `rim`, its size. Lit, it turns toward
    /// its light by its `normals`, a normal map, or by a `rim` on its edges.
    func quad(_ texture: MTLTexture, x: Double, y: Double, source s: Rect, size: Size? = nil, flip: Bool = false, color: UInt32 = 0xFFFFFF,
              opacity: Double = 1, flash: Double = 0, keep: Double = 1, glows: Bool = false, state: MTLRenderPipelineState? = nil,
              values: [Float]? = nil, frame: SIMD2<Float> = .zero, normals: MTLTexture? = nil, rim: Bool = false) {
        let k = current?.grid ?? Double(scale) // corners on k-ths of a pixel, so whole pixels stay whole and the rest lands between
        let x0 = Float(((x - offset.x) * k).rounded(.down) / k), y0 = Float(((y - offset.y) * k).rounded(.down) / k)
        let (x1, y1) = (x0 + Float(size?.width ?? s.width), y0 + Float(size?.height ?? s.height))
        let (w, h) = (Float(texture.width), Float(texture.height))
        var (u0, u1) = (Float(s.x) / w, Float(s.x + s.width) / w)
        let (v0, v1) = (Float(s.y) / h, Float(s.y + s.height) / h)
        if flip { swap(&u0, &u1) }
        if glows && blooming { glowed.append(Glowed(texture: texture, box: [x0, y0, x1, y1], uv: [u0, v0, u1, v1], color: tint(color, opacity), flash: Float(flash))) }
        let lit = lighting != .none && !glows, shape: Float = glows ? 1 : !lit ? 0 : normals != nil ? 2 : rim ? 3 : 0 // how it's drawn
        queue(texture, [x0, y0, x1, y1], uv: [u0, v0, u1, v1], color: tint(color, opacity),
              effects: [Float(flash), Float(keep), lighting.rawValue, shape], more: [Float(feet.x), Float(feet.y), frame.x, frame.y],
              stand: lighting == .raised ? stand : .zero, state: state, values: values, normals: lit ? normals : nil)
    }

    /// Queues a quad over `box`, from x0, y0 to x1, y1 in the pass's units, its texture coordinates `uv` the same way, and
    /// the rest of its corners as given. Consecutive quads with the same texture, pipeline and values reach the GPU as
    /// one draw call.
    func queue(_ texture: MTLTexture, _ box: SIMD4<Float>, uv: SIMD4<Float> = [0, 0, 1, 1], color: SIMD4<Float> = [1, 1, 1, 1],
               effects: SIMD4<Float> = [0, 1, 0, 0], more: SIMD4<Float> = .zero, stand: SIMD4<Float> = .zero, state: MTLRenderPipelineState? = nil,
               values: [Float]? = nil, normals: MTLTexture? = nil) {
        let (x0, y0, x1, y1) = (box[0], box[1], box[2], box[3])
        queue(texture, corners: [[x0, y0], [x1, y0], [x0, y1], [x1, y1]], uv: uv, color: color, effects: effects, more: more, stand: stand, state: state,
              values: values, normals: normals)
    }

    /// Queues a quad with its corners anywhere, top left, top right, bottom left and bottom right, as `queue(_:_:)` does
    /// one over a box: a diamond on an isometric floor.
    func queue(_ texture: MTLTexture, corners c: [SIMD2<Float>], uv: SIMD4<Float> = [0, 0, 1, 1], color: SIMD4<Float> = [1, 1, 1, 1],
               effects: SIMD4<Float> = [0, 1, 0, 0], more: SIMD4<Float> = .zero, stand: SIMD4<Float> = .zero, state: MTLRenderPipelineState? = nil,
               values: [Float]? = nil, normals: MTLTexture? = nil) {
        let state = state ?? current?.usual ?? pipeline
        if texture !== batch?.texture || state !== batch?.state || values != batch?.values || normals !== batch?.normals {
            flush()
            batch = (texture, state, values, normals)
        }
        let (u0, v0, u1, v1) = (uv[0], uv[1], uv[2], uv[3])
        for corner in [[c[0].x, c[0].y, u0, v0], [c[1].x, c[1].y, u1, v0], [c[2].x, c[2].y, u0, v1], [c[1].x, c[1].y, u1, v0], [c[3].x, c[3].y, u1, v1],
                       [c[2].x, c[2].y, u0, v1]] as [SIMD4<Float>] {
            vertices += [corner, color, effects, more, stand]
        }
    }

    func flush() {
        if let batch, !vertices.isEmpty {
            let encoder = self.encoder
            if drawing !== batch.state {
                encoder.setRenderPipelineState(batch.state)
                drawing = batch.state
            }
            let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(batch.texture, index: 0)
            encoder.setFragmentTexture(batch.normals ?? white, index: 5) // its normal map, for light that shapes it
            if let values = batch.values { encoder.setFragmentBytes(values, length: values.count * MemoryLayout<Float>.stride, index: 1) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 5)
        }
        vertices.removeAll(keepingCapacity: true)
        batch = nil
    }

    /// Begins a frame's pass on `commands`: the canvas's, or the drawable's (`state` then the canvas drawn on it).
    func begin(_ commands: MTLCommandBuffer, _ descriptor: MTLRenderPassDescriptor, _ state: MTLRenderPipelineState? = nil) {
        self.commands = commands
        (lit, view) = (false, makeView(origin: .zero, maps: Size(1, 1), ambient: [1, 1, 1]))
        go(Pass(descriptor: descriptor, usual: state ?? pipeline, grid: Double(scale), size: size, textures: [white, white, white, white]))
    }

    /// Ends the pass under way, if it's begun, keeping what it drew, and goes on with `pass`, which begins as the first
    /// quad reaches it.
    func go(_ pass: Pass) {
        interrupt()
        for i in 0..<8 where pass.descriptor.colorAttachments[i].texture != nil { pass.descriptor.colorAttachments[i].storeAction = .store }
        current = pass
    }

    /// Ends the pass's encoder if it's begun, so something else can be encoded; the next quad begins it again, on what
    /// it drew.
    func interrupt() {
        flush()
        guard let open else { return }
        open.endEncoding()
        self.open = nil
        for i in 0..<8 where current.descriptor.colorAttachments[i].texture != nil { current.descriptor.colorAttachments[i].loadAction = .load }
    }

    private func opened() -> MTLRenderCommandEncoder {
        let encoder = commands.makeRenderCommandEncoder(descriptor: current.descriptor)!
        (open, drawing) = (encoder, nil)
        encoder.setVertexBytes([SIMD2<Float>(Float(current.size.width), Float(current.size.height))], length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setVertexBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 2) // for `litVertex`
        encoder.setFragmentBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 0)
        for (i, texture) in current.textures.enumerated() {
            encoder.setFragmentTexture(texture, index: i + 1)
            encoder.setVertexTexture(texture, index: i + 1)
        }
        return encoder
    }

    func end() {
        flush()
        // A pass that would only load its texture and store it again, as the canvas's after a game's effects with nothing
        // drawn since, isn't begun: on an iPhone that's the whole 9-times canvas read and written for nothing.
        if open == nil, current.descriptor.colorAttachments[0].loadAction == .load { return }
        encoder.endEncoding()
        open = nil
    }

    /// The `View` the shaders read: the canvas's scale; whether there are clouds, 1 dithered and 2 smooth, whether fog is
    /// smooth, and whether there's a vignette; the view's offset, the light maps' first texel's world pixel and their
    /// size, the game's size, and the daylight's color.
    func makeView(origin: Vector, maps: Size, ambient: SIMD3<Float>, clouds: Float = 0, fog: Bool = false, vignette: Bool = false) -> [Float] {
        [Float(scale), clouds, fog ? 1 : 0, vignette ? 1 : 0, Float(offset.x), Float(offset.y), Float(origin.x), Float(origin.y),
         Float(maps.width), Float(maps.height), Float(size.width), Float(size.height), ambient.x, ambient.y, ambient.z, 0]
    }

    /// How a quad is lit by the scene's light maps (`lit` in the shaders).
    enum Lighting: Float {
        /// Not at all, as a HUD isn't.
        case none = 0
        /// By the light at its pixel: the ground, and entities in a scene that isn't `ySort`.
        case pixel = 1
        /// By the light at its pixel without shadows: the layers above, high over what casts them.
        case open = 2
        /// By the light at its pixel without shadows, times the share of it that gets through them to its feet, so it's
        /// lit or in shadow as a whole: entities standing in a `ySort` scene.
        case standing = 3
        /// By daylight alone, the ambient and the clouds: backdrops and overhangs.
        case daylight = 4
        /// By the light on the floor under each of its pixels, where the view's ray through the pixel meets its box
        /// (`stand`), less of it the further up that is: what stands in an isometric scene.
        case raised = 5
    }

    /// A render pass quads go to: its descriptor, the pipeline they draw with unless they say, the grid their corners land
    /// on (`grid`-ths of a pixel), the size their positions are given in, over all of its textures, and the textures bound
    /// for every quad's fragments from index 1.
    struct Pass {
        var descriptor: MTLRenderPassDescriptor
        var usual: MTLRenderPipelineState
        var grid = 1.0
        var size: Size
        var textures: [MTLTexture] = []
    }
}

/// A pipeline from `library`'s `vertex` and `fragment` functions, drawing into textures of `formats`, each blended the
/// same way: `rgb`'s and `alpha`'s factors, with `operation`; those `masked` it leaves as they are.
func makeState(_ library: MTLLibrary, _ fragment: String, vertex: String = "spriteVertex", formats: [MTLPixelFormat], rgb: (MTLBlendFactor, MTLBlendFactor),
               alpha: (MTLBlendFactor, MTLBlendFactor), operation: (rgb: MTLBlendOperation, alpha: MTLBlendOperation) = (.add, .add),
               masked: [Int] = []) -> MTLRenderPipelineState {
    let pipeline = MTLRenderPipelineDescriptor()
    pipeline.vertexFunction = library.makeFunction(name: vertex)
    pipeline.fragmentFunction = library.makeFunction(name: fragment)
    for (i, format) in formats.enumerated() {
        let color = pipeline.colorAttachments[i]!
        color.pixelFormat = format
        color.isBlendingEnabled = true
        (color.sourceRGBBlendFactor, color.destinationRGBBlendFactor) = rgb
        (color.sourceAlphaBlendFactor, color.destinationAlphaBlendFactor) = alpha
        (color.rgbBlendOperation, color.alphaBlendOperation) = operation
        if masked.contains(i) { color.writeMask = [] }
    }
    do { return try library.device.makeRenderPipelineState(descriptor: pipeline) } catch {
        fatalError("Spellcrest: can't make the pipeline for \(fragment): \(error)")
    }
}

/// A color, 0xRRGGBB, and an opacity, as a shader's: r, g, b and a from 0 to 1.
func tint(_ color: UInt32, _ opacity: Double = 1) -> SIMD4<Float> {
    [Float(color >> 16 & 0xFF) / 255, Float(color >> 8 & 0xFF) / 255, Float(color & 0xFF) / 255, Float(opacity)]
}

/// A color, 0xRRGGBB, to clear a render pass to.
func clearColor(_ rgb: UInt32) -> MTLClearColor {
    MTLClearColor(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255, alpha: 1)
}

/// The biggest scale of `canvas` that fits in `drawable`, so on a phone the game reaches the screen's edges: at the top
/// when the screen is taller than wide, below `top` (the safe area's inset there, the Dynamic Island's, in the
/// drawable's units), leaving the rest to the touch controls, and centered otherwise. Not a whole number, so the
/// canvas, drawn at the nearest whole one (`canvasScale`), is scaled the rest of the way smoothly.
func fit(_ canvas: Size, in drawable: CGSize, top: Double = 0) -> MTLViewport {
    let upright = drawable.height > drawable.width
    let room = upright ? drawable.height - top : drawable.height
    let scale = min(drawable.width / Double(canvas.width), room / Double(canvas.height))
    let (width, height) = (Double(canvas.width) * scale, Double(canvas.height) * scale)
    return MTLViewport(originX: (drawable.width - width) / 2, originY: upright ? top : (drawable.height - height) / 2,
                       width: width, height: height, znear: 0, zfar: 1)
}

/// How many times the game's size the canvas is drawn at for a drawable: the whole number `letterbox` scales it by, so
/// it reaches the screen pixel for pixel, or where it `fill`s the drawable (`fit`, on iOS) the nearest to that scale,
/// the canvas then scaled the rest of the way, on an iPhone 16 Pro by 0.99 sideways and 1.005 upright.
func canvasScale(_ canvas: Size, in drawable: CGSize, fill: Bool) -> Int {
    guard fill else { return Int(letterbox(canvas, in: drawable).width) / canvas.width }
    return max(1, Int(min(drawable.width / Double(canvas.width), drawable.height / Double(canvas.height)).rounded()))
}

/// The canvas pixel at `point` when the canvas shows in `viewport` (`fit`'s or `letterbox`'s, in the same units, from
/// the top left), in whole pixels, and off the canvas when the point is.
func pixel(at point: CGPoint, in viewport: MTLViewport, canvas: Size) -> Vector {
    let scale = viewport.width / Double(canvas.width)
    return [((point.x - viewport.originX) / scale).rounded(.down), ((point.y - viewport.originY) / scale).rounded(.down)]
}

/// The biggest whole-number scale of `canvas` that fits in `drawable` (at least 1x), centered.
func letterbox(_ canvas: Size, in drawable: CGSize) -> MTLViewport {
    let (w, h) = (Int(drawable.width), Int(drawable.height))
    let scale = max(1, min(w / canvas.width, h / canvas.height))
    let (sw, sh) = (canvas.width * scale, canvas.height * scale)
    return MTLViewport(
        originX: Double((w - sw) / 2), originY: Double((h - sh) / 2),
        width: Double(sw), height: Double(sh), znear: 0, zfar: 1)
}

// Compiled at runtime, so building games doesn't need the offline Metal toolchain. What the engine's shaders and a
// game's own share: the structs, noise, the dither, and reading the scene's light. Each line it adds to the engine's
// library is compiled as a game starts, so keep it small.
let shaderCommon = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float4 position [[position]]; float2 uv; float4 color [[flat]]; float4 effects [[flat]]; float4 more [[flat]];
    float3 shade [[flat]]; // for a standing quad, the share of the light at its feet that gets through the shadows (litVertex)
    float4 stand [[flat]]; // for one standing in an isometric picture, its footprint's front edges and its height (Screen.stand)
};

// As Screen.queue writes them: x, y in the pass's pixels (y down) and u, v texture coords; the color to multiply by;
// then what the fragments make of it: for a sprite, how far to mix toward white (a flash), how much of a dissolve's
// pattern to keep, how it's lit and whether it glows; its feet in world pixels and its frame's place in the texture; and
// in an isometric picture, where it stands.
struct Corner { float4 xyuv; float4 color; float4 effects; float4 more; float4 stand; };

// How the canvas lies over the world, and the light maps under it (Screen.view).
struct View {
    float scale;    // the canvas's pixels to each of the game's
    float clouds;   // 0 none, 1 dithered, 2 smooth, read between the game's pixels
    float fog;      // 1: its thickness read between the game's pixels
    float vignette; // 1: the open map's alpha is a vignette
    float2 offset;  // the world pixel at the view's top left: the camera, shaken
    float2 origin;  // the world pixel at the light maps' first texel
    float2 size;    // the light maps' size in texels
    float2 canvas;  // the game's size in pixels
    float4 ambient; // the daylight's color
};

// What a game's shader is given besides its pixel: the scene's time in seconds, the canvas's size in the game's pixels,
// and the numbers the game gave it, values[0] to values[15] (Shader in Swift).
struct Values {
    float time;
    float unused;
    float2 size;
    float numbers[16];
    float operator[](int i) const { return numbers[clamp(i, 0, 15)]; }
};

// The picture drawn so far, for a layer shader: layer.sample(position) is its color there, in the game's pixels.
struct Layer {
    texture2d<float> picture;
    float scale;
    half4 sample(float2 position) const {
        constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
        return half4(picture.sample(nearest, position * scale / float2(picture.get_width(), picture.get_height())));
    }
};

// A 4x4 ordered dither: the order a dissolve's pixels go in, and the steps of a dithered edge.
constant float bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

// Where a pixel comes in the 4x4 pattern, from 0 to 15/16.
float order(float2 pixel) { int2 cell = int2(floor(pixel)) & 3; return bayer[cell.y * 4 + cell.x] / 16; }

// The same in the middle of each step, for dithering: floor(shade * steps + dither(pixel)) / steps.
float dither(float2 pixel) { return order(pixel) + 1.0 / 32; }

float luma(float3 rgb) { return dot(rgb, float3(0.299, 0.587, 0.114)); }

float hash(float2 p) {
    float3 q = fract(float3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Smooth value noise from 0 to 1, changing about once a unit.
float noise(float2 p) {
    float2 i = floor(p), f = fract(p), u = f * f * (3 - 2 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

// Four octaves of noise, from 0 to 1: clouds, fog, smoke.
float fbm(float2 p) {
    float sum = 0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amplitude * noise(p);
        p = p * 2.02 + float2(17.3, 9.1);
        amplitude *= 0.5;
    }
    return sum / 0.9375;
}

// A light map at a world pixel: the texel the pixel's in, so each of the game's pixels is lit as a whole, as its art is,
// sharp, where reading between them blurred the light's edges over a pixel.
float4 at(texture2d<float> map, float2 world, constant View &view) {
    return map.read(uint2(clamp(world - view.origin, float2(0), view.size - 1)));
}

// A map at a world pixel between the texels around it, for what's smooth: soft clouds and fog.
float4 between(texture2d<float> map, float2 world, constant View &view) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    return map.sample(linear, (world - view.origin) / view.size, level(0)); // a level of its own, so a vertex function could too
}

// How much daylight the clouds leave at a world pixel, from their own map: 1 without clouds.
float cloudy(texture2d<float> clouds, float2 world, constant View &view) {
    if (view.clouds < 0.5) return 1;
    return (view.clouds > 1.5 ? between(clouds, world, view) : at(clouds, world, view)).r;
}

// A color in a light: multiplied by it, and past daylight, 1, going toward the light's own white; its alpha drains it
// toward gray.
float3 shine(float3 rgb, float4 light) {
    float3 l = max(light.rgb, float3(0));
    float peak = max(l.r, max(l.g, l.b));
    rgb = mix(rgb * l, l / max(peak, 1.0), saturate((peak - 1) * 0.55));
    return mix(rgb, float3(luma(rgb)), saturate(light.a));
}

// Where on an isometric floor a pixel standing at `world`, in the picture, is lit from: under the point where the view's
// ray through it meets its box (`stand`: its footprint's front edges, x1 and y1, and its height), a world pixel out from
// the face it meets, so each face is lit from its own side; and how far up that point is. The ray's points are the
// floor's x + y = u, at x = (u + world.x) / 2, y = (u - world.x) / 2 and a height of u / 2 - world.y, and the box's
// nearest is where u first meets a front face or its top, never under the floor.
float3 underfoot(float2 world, float4 stand) {
    float right = 2 * stand.x - world.x, left = 2 * stand.y + world.x, top = 2 * world.y + 2 * stand.z;
    float u = max(min(min(right, left), top), 2 * world.y);
    float2 under = float2(world.x, u / 2);
    if (u > 2 * world.y && u < top) under += right <= left ? float2(1, 0.5) : float2(-1, 0.5);
    return float3(under, u / 2 - world.y);
}

// How much of the light past the daylight reaches a pixel `height` pixels above an isometric floor: all of it at its
// foot, half 64 pixels up, as a lamp lights a wall's foot more than its top.
float fade(float height) { return 1 / (1 + max(height, 0.0) / 64); }

// A canvas pixel's color as the scene's light maps light it, as `mode` says (Screen.Lighting): 0 not at all; 1 by its
// pixel's light; 2 by its pixel's without shadows; 3 standing, by that times `shade`, the share of the light at its
// feet that gets through the shadows; 4 by daylight alone; 5 raised, by the light on an isometric floor under it, what
// lights it past the daylight fading as it rises (`stand`). The shadowed map's alpha is how gray, the open one's the
// vignette. The clouds have a map of their own, so they can be soft while the light is sharp: the daylight they take,
// the ambient darkened by the vignette times their shade, comes off the light here, and the cap at daylight left room
// for it (`capFragment`).
float3 raised(float3 rgb, float2 pixel, float4 stand, constant View &view, texture2d<float> shadowed, texture2d<float> open,
              texture2d<float> clouds) {
    float3 under = underfoot(pixel / view.scale + view.offset, stand);
    float4 here = at(shadowed, under.xy, view);
    float left = cloudy(clouds, under.xy, view);
    float4 sky = at(open, under.xy, view);
    float3 taken = view.ambient.rgb * sky.a * (1 - left), daylight = view.ambient.rgb * sky.a * left;
    return shine(rgb, float4(mix(daylight, here.rgb - taken, fade(under.z)), here.a));
}

float3 lit(float3 rgb, float mode, float3 shade, float2 pixel, constant View &view, texture2d<float> shadowed, texture2d<float> open,
           texture2d<float> clouds, float4 stand = float4(0)) {
    if (mode < 0.5) return rgb;
    if (mode > 4.5) return raised(rgb, pixel, stand, view, shadowed, open, clouds);
    float2 world = pixel / view.scale + view.offset;
    float4 here = at(shadowed, world, view);
    float left = cloudy(clouds, world, view);
    float4 sky = mode > 1.5 || (left < 1 && view.vignette > 0.5) ? at(open, world, view) : float4(1);
    float3 taken = view.ambient.rgb * sky.a * (1 - left);
    if (mode < 1.5) return shine(rgb, float4(here.rgb - taken, here.a));
    if (mode > 3.5) return shine(rgb, float4(view.ambient.rgb * sky.a * left, here.a));
    return shine(rgb, float4((sky.rgb - taken) * (mode > 2.5 ? shade : float3(1)), here.a));
}

Vertex corner(uint i, constant Corner *v, constant float2 &size) {
    float2 p = v[i].xyuv.xy / size * 2 - 1;
    return { float4(p.x, -p.y, 0, 1), v[i].xyuv.zw, v[i].color, v[i].effects, v[i].more, float3(1), v[i].stand };
}

vertex Vertex spriteVertex(uint i [[vertex_id]], constant Corner *v [[buffer(0)]], constant float2 &size [[buffer(1)]]) { return corner(i, v, size); }

// The world's quads on the canvas: a standing one's share of the light at its feet (more.xy) that gets through the
// shadows, read once a corner rather than at each of its pixels.
vertex Vertex litVertex(uint i [[vertex_id]], constant Corner *v [[buffer(0)]], constant float2 &size [[buffer(1)]], constant View &view [[buffer(2)]],
                        texture2d<float> shadowed [[texture(1)]], texture2d<float> open [[texture(2)]]) {
    Vertex out = corner(i, v, size);
    if (v[i].effects.z > 2.5 && v[i].effects.z < 3.5) {
        out.shade = saturate(at(shadowed, v[i].more.xy, view).rgb / max(at(open, v[i].more.xy, view).rgb, float3(0.0001)));
    }
    return out;
}

"""

// The engine's own fragments, for the canvas and the screen.
let shaderEngine = """
// A sprite, a tile, text or a fill: its texture's pixel times its color, mixed toward white by a flash, dropped in a
// dissolve's pattern but for the share to keep, and lit as it says.
fragment float4 spriteFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                               texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], texture2d<float> direction [[texture(4)]],
                               texture2d<float> normals [[texture(5)]], constant View &view [[buffer(0)]]) {
    if (order(in.position.xy / view.scale) >= in.effects.y) discard_fragment(); // the game's pixels, at any scale
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    float3 rgb = mix(c.rgb, float3(1), saturate(in.effects.x));
    float3 out = lit(rgb, in.effects.z, in.shade, in.position.xy, view, shadowed, open, clouds, in.stand);
    float flip = dfdx(in.uv.x) < 0 ? -1 : 1; // mirrored, its texture's left is the screen's right
    float2 pixel = in.position.xy; // standing in an isometric picture, the way to the light is the floor's under it, as the pixel it's drawn at
    if (in.effects.z > 4.5) pixel = (underfoot(pixel / view.scale + view.offset, in.stand).xy - view.offset) * view.scale;
    if (in.effects.w > 1.5) out = shaped(out, in.effects.w < 2.5, in.uv, flip, in.more.zw, pixel, t, normals, direction, view); // 2 normal map, 3 rim
    return float4(out, c.a);
}

// A sprite that glows, added to what's under it and unlit: fire, magic, sparks.
fragment float4 glowFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], constant View &view [[buffer(0)]]) {
    if (order(in.position.xy / view.scale) >= in.effects.y) discard_fragment();
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    return float4(mix(c.rgb, float3(1), saturate(in.effects.x)) * c.a, c.a);
}

// The canvas on the screen: at its size there pixel for pixel, or scaled the last little way, which nearest-neighbor
// would do by making some of the game's pixels a screen pixel wider than the rest.
fragment float4 smoothFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler linear(filter::linear);
    return t.sample(linear, in.uv);
}

// A backdrop or an overhang over the view: its image from effects.xy in the view's pixels, each row swayed up to
// effects.z pixels by the time, effects.w; repeated across if more.x, down if more.y; lit as more.z says.
fragment float4 parallaxFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                                 texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    float2 size = float2(t.get_width(), t.get_height());
    float2 p = in.position.xy / view.scale - in.effects.xy;
    p.x -= sin(in.effects.w * 1.4 + floor(p.y) * 0.11) * in.effects.z;
    if (in.more.x > 0.5) p.x -= floor(p.x / size.x) * size.x; else if (p.x < 0 || p.x >= size.x) discard_fragment();
    if (in.more.y > 0.5) p.y -= floor(p.y / size.y) * size.y; else if (p.y < 0 || p.y >= size.y) discard_fragment();
    float4 c = t.read(uint2(min(p, size - 1)));
    if (c.a == 0) discard_fragment();
    return float4(lit(c.rgb, in.more.z, float3(1), in.position.xy, view, shadowed, open, clouds), c.a);
}

// Fog over the world: its color, as thick as its map (texture 0) says at each world pixel, or between them if it's
// smooth, lit as the ground is.
fragment float4 fogFragment(Vertex in [[stage_in]], texture2d<float> fog [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                            texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    float2 world = in.position.xy / view.scale + view.offset;
    float thick = (view.fog > 0.5 ? between(fog, world, view) : at(fog, world, view)).r;
    if (thick <= 0) discard_fragment();
    return float4(lit(in.color.rgb, 1, float3(1), in.position.xy, view, shadowed, open, clouds), thick);
}

"""

/// Where a game file, `<name>.<extension>`, is: anywhere in `Assets`, at the top first, then in its folders by path, so
/// games keep their sprites, maps and sounds in folders and find them by name. `Assets/Parts`, a kit of the parts
/// people are made of (`KitFile`), isn't looked in: a game draws the people, so a part's name can't hide a sprite's. `Assets` is inside the app once the game
/// has been exported, otherwise in the folder the game runs in (the editor runs games in their project folder).
/// A file that isn't where it was, or wasn't there, is looked for again once a folder in `Assets` has changed, which is
/// looked at no more than once a second (the loop checks loaded files 4 times a second), so files added or moved while
/// the game runs are found. In an app, whose files can't change, it's never looked for again.
func assetURL(_ file: String) -> URL {
    let root = bundledAssets ?? URL(fileURLWithPath: "Assets")
    return assetIndex.withLock { index in
        func found() -> URL? { index.files[file].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
        if index.root == root, let url = found() { return url }
        if index.root != root || index.stale() { index.build(root) }
        return found() ?? root.appending(path: file)
    }
}

private let bundledAssets = Bundle.main.url(forResource: "Assets", withExtension: nil)
/// Whether the game's files can change while it runs, saved by the editor: not once they're inside an app, where
/// they're signed, as on an iPhone or iPad. Only then does the loop look for files that changed.
let assetsCanChange = bundledAssets == nil
let assetIndex = Mutex(AssetIndex())

/// The names of the files in an app's `Assets` with one of `extensions`, without it; none outside an app.
func bundledNames(_ extensions: Set<String>) -> [String] {
    guard let root = bundledAssets else { return [] }
    let names = (FileManager.default.subpaths(atPath: root.path) ?? []).compactMap { path -> String? in
        let file = (path as NSString).lastPathComponent as NSString
        return extensions.contains(file.pathExtension) ? file.deletingPathExtension : nil
    }
    return Set(names).sorted()
}

/// What `read` makes of the file `key`, kept in `kept` the first time in an app, whose files can't change, so it's
/// read once; read each time where they can (`keeping` false), as in the editor, which may have saved it since.
func once<Value: Sendable>(_ key: String, in kept: borrowing Mutex<[String: Value]>, keeping: Bool = !assetsCanChange,
                           _ read: () throws -> Value) rethrows -> Value {
    if keeping, let value = kept.withLock({ $0[key] }) { return value }
    let value = try read()
    if keeping { kept.withLock { $0[key] = value } }
    return value
}

/// What the console has said that's best said once, like that a file is missing, by what it's about.
let said = Mutex<Set<String>>([])

/// Prints `message` the first time something is said about `key`, from any thread.
func say(once key: String, _ message: @autoclosure () -> String) {
    if said.withLock({ $0.insert(key).inserted }) { print(message()) }
}

/// The files in `Assets` and its folders, by name.
struct AssetIndex {
    var root: URL?
    var files: [String: URL] = [:]
    var folders: [(url: URL, modified: Date?)] = [] // `Assets` and its folders, which change as a file in one is added, moved or deleted
    var checked = Date.distantPast // when the folders were last looked at
    var warned: Set<String> = []

    /// Names must be unique among files of one type; of two, the first by path wins, and the console says so.
    mutating func build(_ root: URL) {
        let paths = (FileManager.default.subpaths(atPath: root.path) ?? [])
            .filter { !$0.split(separator: "/").contains { $0.hasPrefix(".") } } // the editor's, like an image's layers
            .filter { $0 != "Parts" && !$0.hasPrefix("Parts/") } // a kit's parts, which people are made of, not drawn
            .sorted { ($0.contains("/") ? 1 : 0, $0) < ($1.contains("/") ? 1 : 0, $1) }
        (self.root, files, folders, checked) = (root, [:], [(root, modificationDate(root))], Date())
        for path in paths {
            let url = root.appending(path: path)
            var folder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue { folders.append((url, modificationDate(url))) }
            let name = (path as NSString).lastPathComponent
            if let first = files[name] {
                if warned.insert(name).inserted { print("Spellcrest: Assets has two files called \(name), so it uses \(first.path), not \(path)") }
            } else {
                files[name] = url
            }
        }
    }

    /// Whether a file may have been added, moved or deleted since it was built: once one of its folders has changed,
    /// looked at no more than once a second. Building it takes a couple of milliseconds; this, a microsecond or two a folder.
    mutating func stale() -> Bool {
        guard assetsCanChange, Date().timeIntervalSince(checked) >= 1 else { return false }
        checked = Date()
        return folders.contains { modificationDate($0.url) != $0.modified }
    }
}

/// When the file at `url` last changed; nil without one. From `stat`, in a microsecond or two, where FileManager's
/// attributes took 10 to 20 for each file the loop checks.
func modificationDate(_ url: URL) -> Date? {
    var status = stat()
    guard url.withUnsafeFileSystemRepresentation({ $0.map { stat($0, &status) } }) == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000)
}

/// The size of `Assets/<name>.png`'s frames, as its `.json` cuts it up, or of the whole image; nil without one. Read
/// `once`.
func frameSize(_ name: String) -> Size? {
    if name.hasPrefix(Person.prefix) { return (try? Person.kit()).map { Size($0.frameWidth, $0.frameHeight) } } // a person's: the kit's frames
    return once(name, in: framesRead) {
        guard let source = CGImageSourceCreateWithURL(assetURL("\(name).png") as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let sheet = try? SheetFile(contentsOf: assetURL("\(name).json"))
        return Size(sheet?.frameWidth ?? width, sheet?.frameHeight ?? height)
    }
}

let framesRead = Mutex<[String: Size?]>([:])

extension SheetFile.Animation {
    /// The frame showing `time` seconds in, looping; nil without frames.
    func frame(at time: Double) -> Int? { frames.isEmpty ? nil : frames[Int(time * fps) % frames.count] }
}
