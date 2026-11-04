import Foundation

/// A bloom over a scene's world (`Scene.bloom`): what glows spills softly past its pixels into the dark around it, as
/// light does in a camera. Only what glows blooms, sprites and particles that glow and lightning bolts, and light past
/// daylight, a flash, so a scene keeps its look but where something shines; and nothing is drawn while nothing does.
public struct Bloom: Sendable, Equatable {
    /// How much it adds: at 1, as much again as what glows, spread out.
    public var strength: Double
    /// About how far it spreads, in the game's pixels.
    public var radius: Double
    /// How much light past daylight blooms, from 0, none, to 1, all of it: a strike's flash, a fireball's light.
    public var light: Double

    /// A bloom adding `strength` of what glows, spread about `radius` pixels, with `light` of the light past daylight:
    /// by default `Bloom()`, a soft halo a few pixels wide.
    public init(strength: Double = 1, radius: Double = 4, light: Double = 0.25) {
        (self.strength, self.radius, self.light) = (strength, radius, light)
    }
}

/// Air that bends the picture around a point in a scene's world (`Scene.bends`): a ring going out where a spell lands,
/// heat haze over a fire, a swirl. Each moves the picture's pixels by up to `strength` within its `radius`, and it's
/// drawn only where it is, so a few cost little more than one.
public struct Bend: Sendable, Equatable {
    /// How a bend moves the picture.
    public enum Kind: Sendable, Equatable {
        /// A ring going out from the middle, pushing the picture outward: at `progress` 0 at the middle, at 1 at the
        /// radius, weakening as it goes, as a shockwave does.
        case ring(progress: Double)
        /// Wavering, as heat haze does over a fire.
        case haze
        /// Turning round the middle, the most near it, as a gloom's swirl.
        case swirl
    }

    /// How it moves the picture.
    public var kind: Kind
    /// Its middle, in world pixels; in an isometric scene, in the picture's pixels, as its camera is.
    public var middle: Vector
    /// How far from its middle it reaches, in pixels.
    public var radius: Double
    /// How far it moves the picture at its strongest, in the game's pixels.
    public var strength: Double

    /// `kind` of bend at `middle`, in world pixels, reaching `radius` and moving the picture by up to `strength`: a
    /// shockwave halfway out is `Bend(.ring(progress: 0.5), at: hit, radius: 80, strength: 3)`.
    public init(_ kind: Kind, at middle: Vector, radius: Double, strength: Double) {
        (self.kind, self.middle, self.radius, self.strength) = (kind, middle, radius, strength)
    }
}

/// A glowing quad as it was queued in a frame with a bloom, to draw again into the bloom's map.
struct Glowed {
    let texture: GPUTexture
    let box, uv, color: SIMD4<Float>
    let flash: Float
}

/// The bloom's and the bends' pipelines: what glows drawn again into the bloom's map, quads and particles, added; the
/// light past daylight; the blur; the bloom added over the canvas; the bends into their map, added; and the canvas drawn
/// through it.
struct GlowStates {
    let into, particlesInto, past, blur, bloom, bends, through: GPUPipeline

    init(_ gpu: GPU, format: PixelFormat) {
        let map: PixelFormat = .rgba16Float
        into = gpu.pipeline("glowFragment", formats: [map], rgb: (.one, .one), alpha: (.one, .one))
        particlesInto = gpu.pipeline("particleGlowFragment", vertex: "particleVertex", formats: [map], rgb: (.one, .one), alpha: (.one, .one))
        past = gpu.pipeline("pastDaylightFragment", formats: [map], rgb: (.one, .one), alpha: (.one, .one))
        blur = gpu.pipeline("blurFragment", formats: [map], rgb: (.one, .zero), alpha: (.one, .zero))
        bloom = gpu.pipeline("bloomFragment", formats: [format], rgb: (.one, .one), alpha: (.zero, .one))
        bends = gpu.pipeline("bendFragment", formats: [map], rgb: (.one, .one), alpha: (.one, .one))
        through = gpu.pipeline("throughFragment", formats: [format], rgb: (.one, .zero), alpha: (.one, .zero))
    }
}

extension Screen {
    /// A map the game's size, of half floats, made the first time it's needed and again if the game's size changes.
    func gameSized(_ kept: inout GPUTexture?) -> GPUTexture {
        if let kept, kept.width == size.width, kept.height == size.height { return kept }
        kept = gpu.texture(.rgba16Float, width: size.width, height: size.height)
        return kept!
    }

    /// Blooms what glowed in the frame so far: the glowing quads kept as they were queued (`glowed`), the particles that
    /// glow (`laid`'s), and with light past daylight its part past it, drawn again into a map the game's size, blurred
    /// across and down, and added over the canvas, the blur and the add only round what glowed, as far as it spreads.
    /// Nothing is drawn when nothing glowed.
    func bloom(_ bloom: Bloom?, _ laid: Laid) {
        defer { (glowed, blooming) = ([], false) }
        let particles = laid.runs.joined().filter(\.blooms)
        let past = bloom.map { $0.light > 0 } == true ? pastDaylight : nil
        guard let bloom, bloom.strength > 0, !glowed.isEmpty || !particles.isEmpty || past != nil else { return }
        let canvas = current!, states = glowStates
        let (a, b) = (gameSized(&bloomMap), gameSized(&bloomSpare))
        let whole: SIMD4<Float> = [0, 0, Float(size.width), Float(size.height)]

        // Where it glowed, and as far round it as the blur reaches.
        var glowing = past ?? [.infinity, .infinity, -.infinity, -.infinity]
        func take(_ box: SIMD4<Float>) { glowing = [min(glowing.x, box.x), min(glowing.y, box.y), max(glowing.z, box.z), max(glowing.w, box.w)] }
        for quad in glowed { take(quad.box) }
        for run in particles { take(run.box) }
        let reach = Float(max(bloom.radius, 0.5) * 3 + 1)
        let area = SIMD4<Float>(max((glowing.x - reach).rounded(.down), 0), max((glowing.y - reach).rounded(.down), 0),
                                min((glowing.z + reach).rounded(.up), whole.z), min((glowing.w + reach).rounded(.up), whole.w))
        guard area.x < area.z, area.y < area.w else { return } // all out of view

        go(Pass(targets: Targets([Target(texture: a, load: .clear(red: 0, green: 0, blue: 0, alpha: 0))]), usual: states.into, size: size))
        for quad in glowed { queue(quad.texture, quad.box, uv: quad.uv, color: quad.color, effects: [quad.flash, 1, 0, 1]) }
        if let buffer = laid.buffer, !particles.isEmpty {
            flush()
            let encoder = self.encoder
            encoder.setPipeline(states.particlesInto)
            drawing = states.particlesInto
            for run in particles {
                encoder.setVertexBuffer(buffer, offset: run.start * 4 * MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentTexture(run.texture, index: 0)
                encoder.draw(vertices: 6, instances: run.count)
            }
        }
        if let past, let maps {
            let box = SIMD4<Float>(max(past.x, 0), max(past.y, 0), min(past.z, whole.z), min(past.w, whole.w))
            if box.x < box.z, box.y < box.w { queue(maps.open, box, color: [Float(bloom.light), 0, 0, 1], state: states.past) }
        }
        end()

        // Blurred across into the second map, then down back into the first, over the area; cleared first, so what the
        // blur reads round the area is nothing.
        for (from, to, way) in [(a, b, SIMD2<Float>(1, 0)), (b, a, SIMD2<Float>(0, 1))] {
            go(Pass(targets: Targets([Target(texture: to, load: .clear(red: 0, green: 0, blue: 0, alpha: 0))]), usual: states.blur, size: size))
            queue(from, area, color: [way.x, way.y, Float(max(bloom.radius, 0.5)), 0])
            end()
        }

        go(canvas)
        let strength = Float(bloom.strength)
        queue(a, area, uv: area / SIMD4(whole.z, whole.w, whole.z, whole.w), color: [strength, strength, strength, 1], state: states.bloom)
    }

    /// Bends the picture where the scene's `bends` are: each drawn into a map of how far each of the game's pixels moves,
    /// the bends adding up; then, while their boxes cover less than half the view, the canvas where they reach copied
    /// into the spare and their boxes drawn back from the copy through the map, the rest of the canvas left as it is,
    /// and otherwise the whole canvas drawn through the map.
    func bend(_ bends: [Bend]) {
        guard !bends.isEmpty else { return }
        let canvas = current!, states = glowStates, map = gameSized(&bendMap)
        let view = SIMD4<Float>(0, 0, Float(size.width), Float(size.height))
        var boxes: [SIMD4<Float>] = []
        go(Pass(targets: Targets([Target(texture: map, load: .clear(red: 0, green: 0, blue: 0, alpha: 0))]), usual: states.bends, size: size))
        for bend in bends where bend.radius > 0 && bend.strength != 0 {
            let (middle, r) = (bend.middle - offset, bend.radius)
            let box = SIMD4<Float>(Float((middle.x - r).rounded(.down)), Float((middle.y - r).rounded(.down)),
                                   Float((middle.x + r).rounded(.up)), Float((middle.y + r).rounded(.up)))
            guard box.x < view.z, box.y < view.w, box.z > 0, box.w > 0 else { continue } // out of view
            let (kind, progress): (Float, Float) = switch bend.kind {
            case let .ring(progress): (0, Float(progress))
            case .haze: (1, 0)
            case .swirl: (2, 0)
            }
            queue(white, box, color: [Float(middle.x), Float(middle.y), Float(r), Float(bend.strength)], effects: [kind, progress, Float(time), 0])
            let reach = Float(abs(bend.strength).rounded(.up) + 1) // how far from its box it can read
            boxes.append([max(box.x - reach, 0), max(box.y - reach, 0), min(box.z + reach, view.z), min(box.w + reach, view.w)])
        }
        end()
        guard !boxes.isEmpty else { return go(canvas) }

        // Over half the view: the whole canvas drawn through the map into the spare, which becomes the canvas.
        if boxes.reduce(0, { $0 + ($1.z - $1.x) * ($1.w - $1.y) }) >= view.z * view.w / 2 {
            go(Pass(targets: Targets([Target(texture: spare, load: .dontCare)]), usual: states.through, grid: Double(scale), size: size))
            queue(self.canvas, view)
            encoder.setFragmentTexture(map, index: 6)
            end()
            turnOver()
            canvas.targets.colors[0] = Target(texture: self.canvas, load: .load)
            return go(canvas)
        }

        // Less: the canvas where each reads, in its pixels, copied into the spare, and their boxes drawn back from the
        // copy through the map, the rest of the canvas left as it is.
        go(canvas)
        interrupt()
        let (k, picture) = (Float(scale), self.canvas)
        commands.copy(picture, to: spare, regions: boxes.compactMap { box in
            let (x, y) = (Int(box.x * k), Int(box.y * k))
            let (width, height) = (min(Int((box.z * k).rounded(.up)), picture.width) - x, min(Int((box.w * k).rounded(.up)), picture.height) - y)
            return width > 0 && height > 0 ? Region(x: x, y: y, width: width, height: height) : nil
        })
        for box in boxes { queue(spare, box, state: states.through) }
        encoder.setFragmentTexture(map, index: 6)
        flush()
    }
}
