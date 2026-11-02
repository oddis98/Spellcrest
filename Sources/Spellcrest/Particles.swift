import MetalKit

/// How particles come out of an entity that carries it (`Entity.emitter`), or a burst of them
/// (`Particles.burst(_:at:count:angle:sortY:)`): sparks, embers, smoke, motes, shards. Each lives a while, moving and
/// changing color as it goes, a square of pixels or an image's frames.
public struct Emitter: Sendable, Equatable {
    /// How many come out a second, from an entity that carries it; a burst gives its own count.
    public var rate: Double
    /// How long each lives, in seconds, at random between these.
    public var life: ClosedRange<Double>
    /// How fast each starts, in pixels a second, at random between these.
    public var speed: ClosedRange<Double>
    /// Which way they go, in radians clockwise from right: a quarter turn, `.pi / 2`, is down.
    public var angle: Double
    /// How wide a spread around `angle` they go in, in radians, at random: `2 * .pi`, the default, is every way.
    public var spread: Double
    /// How far from where they come out each starts, at random, in pixels: 0 is all from one point.
    public var area: Double
    /// Where they come out, in pixels from the entity's middle or the burst's point, as a light's `offset` is: a
    /// torch's flame above its post.
    public var offset: Vector
    /// What pulls them, in pixels a second each second: `[0, 60]` falls, `[0, -30]` rises as embers do.
    public var gravity: Vector
    /// How quickly they slow, each second: 0 keeps their speed, 2 loses most of it in a second.
    public var drag: Double
    /// How much they wander, at random, in pixels a second each second: a mote's drift, a flame's flicker.
    public var jitter: Double
    /// Their colors over their life, 0xRRGGBB, evenly, each mixing into the next: a spark from white through gold to
    /// red. One color stays that color. An image's own colors are multiplied by them, so white leaves them as they are.
    public var colors: [UInt32]
    /// Whether each fades out as it dies.
    public var fade: Bool
    /// How many pixels square each is, without an `image`.
    public var size: Int
    /// An image each is drawn as, its frames played once over its life, `Assets/<image>.png` cut up by its `.json`: a
    /// puff of smoke that grows and thins, a leaf. Nil, the default, draws a square `size` pixels across.
    public var image: ImageName?
    /// Added to what's under them and unlit, so they shine in the dark, as sparks do; otherwise drawn over it and lit
    /// as the ground is, as smoke is.
    public var glows: Bool
    /// Where they draw among the scene's entities.
    public var depth: Depth

    /// Where particles draw among a scene's entities.
    public enum Depth: Sendable, Equatable {
        /// As something standing where they came out would, among the entities of a `ySort` scene, so a spark from
        /// behind a pillar stays behind it as it flies up: the default. In a scene that isn't `ySort`, over the entities.
        case standing
        /// On the ground, under every entity: dust, ripples, a footprint's puff.
        case ground
        /// In the air, over every entity and the map's layers above them, under the fog: sparks thrown high, ash.
        case air
    }

    /// Particles as you say, every part of it optional: by default white pixels that glow, going every way at 10 to 40
    /// pixels a second for 0.3 to 0.7 seconds, fading as they die. Embers rising off a fire, gold cooling to red:
    /// `Emitter(rate: 20, speed: 5...15, angle: -.pi / 2, spread: 1, gravity: [0, -20], colors: [0xFFE9A0, 0xC25A1A])`.
    public init(rate: Double = 0, life: ClosedRange<Double> = 0.3...0.7, speed: ClosedRange<Double> = 10...40, angle: Double = 0,
                spread: Double = 2 * .pi, area: Double = 0, offset: Vector = .zero, gravity: Vector = .zero, drag: Double = 0,
                jitter: Double = 0, colors: [UInt32] = [0xFFFFFF], fade: Bool = true, size: Int = 1, image: ImageName? = nil,
                glows: Bool = true, depth: Depth = .standing) {
        (self.rate, self.life, self.speed, self.angle, self.spread, self.area, self.offset) = (rate, life, speed, angle, spread, area, offset)
        (self.gravity, self.drag, self.jitter) = (gravity, drag, jitter)
        (self.colors, self.fade, self.size, self.image, self.glows, self.depth) = (colors, fade, size, image, glows, depth)
    }
}

/// Rain or snow falling over a scene's world (`Scene.weather`), lit as the map's layers above the entities are: rain in
/// streaks that catch the light, adding to what's under them, splashing on the ground; or snow drifting down, swaying.
/// It's the same wherever the view goes.
public struct Weather: Sendable, Equatable {
    /// What falls.
    public enum Kind: Sendable, Equatable {
        /// Streaks falling fast, splashing where they land.
        case rain
        /// Flakes drifting down, swaying.
        case snow
    }

    /// What falls.
    public var kind: Kind
    /// How much: 1 is a steady rain or snow, 2 a downpour or a blizzard, 0.3 a drizzle or a few flakes.
    public var amount: Double
    /// Which way the wind takes it, and how fast, in pixels a second.
    public var wind: Vector
    /// Its color, 0xRRGGBB.
    public var color: UInt32

    /// `kind` falling, `amount` of it, blown by `wind`, in `color`: by default a steady rain, pale blue, or snow, white,
    /// blown a little to the left.
    public init(_ kind: Kind, amount: Double = 1, wind: Vector = [-20, 0], color: UInt32? = nil) {
        (self.kind, self.amount, self.wind) = (kind, amount, wind)
        self.color = color ?? (kind == .rain ? 0xA9BCD6 : 0xF2F4F8)
    }

    /// A steady rain.
    public static let rain = Weather(.rain)
    /// Steady snow.
    public static let snow = Weather(.snow)
}

/// A scene's particles (`Scene.particles`), moved with its updates, whether or not the game calls super, and drawn with
/// its world: up to 20,000 at once, those out of view left out. The same game makes the same particles each run.
@MainActor public final class Particles {
    // Kept in plain arrays, a field to an array, and moved in plain loops, since debug builds are slow; one that dies is
    // swapped with the last.
    var x: [Float] = [], y: [Float] = [], vx: [Float] = [], vy: [Float] = [], age: [Float] = [], life: [Float] = []
    var sortY: [Double] = [] // where each draws among the entities of a `ySort` scene
    var kind: [Int] = [] // its kind, in `kinds`
    var kinds: [Kind] = []
    var motions: [SIMD4<Float>] = [] // each kind's gravity, drag and jitter, as `update` reads them
    var random = Seeded(state: 0x5EED)
    static let most = 20_000 // at once: a burst past it puts out only what there's room for

    /// How many are alive.
    public var count: Int { x.count }

    /// Puts out `count` particles at `point`, in world pixels, as `emitter` says but for its `rate`, going `angle` instead
    /// of its own if you give one: sparks where a bolt lands, `particles.burst(sparks, at: hit, count: 30)`. Among the
    /// entities of a `ySort` scene, those standing draw as something standing at `point` would, or at `sortY` if you give
    /// one: an entity's `sortY`, so sparks off something hit draw in front of it. In an isometric scene, particles are in
    /// the picture, as its camera is: `point` is where they start there, and they fall down it.
    public func burst(_ emitter: Emitter, at point: Vector, count: Int, angle: Double? = nil, sortY: Double? = nil) {
        let room = min(count, Particles.most - x.count)
        guard room > 0 else { return }
        let k = index(of: Kind(emitter)), from = point + emitter.offset, depth = sortY ?? point.y
        for _ in 0..<room {
            let turn = (angle ?? emitter.angle) + Double.random(in: -0.5...0.5, using: &random) * emitter.spread
            let speed = Double.random(in: emitter.speed, using: &random)
            var start = from
            if emitter.area > 0 {
                let (near, around) = (Double.random(in: 0...emitter.area, using: &random), Double.random(in: 0..<(2 * .pi), using: &random))
                start += [cos(around) * near, sin(around) * near]
            }
            x.append(Float(start.x))
            y.append(Float(start.y))
            vx.append(Float(cos(turn) * speed))
            vy.append(Float(sin(turn) * speed))
            age.append(0)
            life.append(Float(Double.random(in: emitter.life, using: &random)))
            self.sortY.append(depth)
            kind.append(k)
        }
    }

    /// Takes every particle away, as a scene might when a spell is broken.
    public func removeAll() {
        (x, y, vx, vy, age, life, sortY, kind) = ([], [], [], [], [], [], [], [])
    }

    /// Moves them on by `dt` seconds, letting those that have lived their life go.
    func update(_ dt: Double) {
        let step = Float(dt)
        var i = 0
        while i < x.count {
            age[i] += step
            if age[i] >= life[i] {
                let last = x.count - 1
                (x[i], y[i], vx[i], vy[i], age[i], life[i], sortY[i], kind[i]) = (x[last], y[last], vx[last], vy[last], age[last], life[last], sortY[last], kind[last])
                x.removeLast(); y.removeLast(); vx.removeLast(); vy.removeLast(); age.removeLast(); life.removeLast(); sortY.removeLast(); kind.removeLast()
                continue
            }
            let motion = motions[kind[i]]
            var (ax, ay) = (motion.x, motion.y)
            if motion.w > 0 {
                ax += Float.random(in: -1...1, using: &random) * motion.w
                ay += Float.random(in: -1...1, using: &random) * motion.w
            }
            vx[i] += ax * step
            vy[i] += ay * step
            if motion.z > 0 {
                let slow = exp(-motion.z * step)
                vx[i] *= slow
                vy[i] *= slow
            }
            x[i] += vx[i] * step
            y[i] += vy[i] * step
            i += 1
        }
    }

    /// The kind's place in `kinds`, added if it's new. Past 64 kinds, as a game whose emitters change as it goes makes
    /// them, those no particle is of any more are let go first.
    func index(of new: Kind) -> Int {
        if let found = kinds.firstIndex(of: new) { return found }
        if kinds.count >= 64 {
            var used = [Bool](repeating: false, count: kinds.count), moved = [Int](repeating: 0, count: kinds.count)
            for k in kind { used[k] = true }
            var (keptKinds, keptMotions): ([Kind], [SIMD4<Float>]) = ([], [])
            for k in kinds.indices where used[k] {
                moved[k] = keptKinds.count
                keptKinds.append(kinds[k])
                keptMotions.append(motions[k])
            }
            for i in kind.indices { kind[i] = moved[kind[i]] }
            (kinds, motions) = (keptKinds, keptMotions)
        }
        kinds.append(new)
        motions.append([Float(new.gravity.x), Float(new.gravity.y), Float(max(new.drag, 0)), Float(max(new.jitter, 0))])
        return kinds.count - 1
    }

    /// The color a particle has `t` of the way through its life, from 0 to 1: its colors, evenly, each mixing into the
    /// next.
    nonisolated static func color(_ colors: [UInt32], at t: Float) -> SIMD4<Float> {
        guard colors.count > 1 else { return tint(colors.first ?? 0xFFFFFF) }
        let at = min(max(t, 0), 0.9999) * Float(colors.count - 1)
        let i = Int(at)
        let (a, b) = (tint(colors[i]), tint(colors[i + 1]))
        return a + (b - a) * (at - Float(i))
    }

    /// What an emitter's particles share once they're out, which is how they move and look: its kind. Two emitters that
    /// differ only in how particles come out, as one aimed another way does, put out particles of one kind.
    struct Kind: Equatable {
        let gravity: Vector, drag: Double, jitter: Double
        let colors: [UInt32], fade: Bool, size: Int, image: ImageName?, glows: Bool, depth: Emitter.Depth

        init(_ e: Emitter) {
            (gravity, drag, jitter) = (e.gravity, e.drag, e.jitter)
            (colors, fade, size, image, glows, depth) = (e.colors, e.fade, max(e.size, 1), e.image, e.glows, e.depth)
        }
    }
}

/// A frame's particles as they're drawn: their instances in one buffer, in the order they draw, and the runs of them
/// drawn at once in each place among the scene's parts: on the ground, standing just behind each entity in its draw
/// order or in front of them all, and in the air. A run is of one image, glowing or not.
struct Laid {
    var buffer: MTLBuffer?
    var runs: [[Run]] = []

    struct Run {
        let start, count: Int
        let texture: MTLTexture
        let glows: Bool
        var blooms = false // glows, and isn't rain, so a scene's bloom draws it again
        var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity) // where its particles are, in the view's pixels
    }
}

/// The number of `sorted` that are at or above `y`: where something at `y` draws among them, after those it ties with.
func place(_ y: Double, among sorted: [Double]) -> Int {
    var (low, high) = (0, sorted.count)
    while low < high {
        let middle = (low + high) / 2
        if sorted[middle] <= y { low = middle + 1 } else { high = middle }
    }
    return low
}

/// A number from 0 to 1, the same for the same `i` and `salt`: where a raindrop or a flake is, and how it falls.
func unit(_ i: Int, _ salt: Int) -> Double {
    var random = Seeded(state: UInt64(bitPattern: Int64(i &* 0x2545_F491 &+ salt &* 0x9E37_79B9)))
    return Double(random.next() >> 11) / Double(1 << 53)
}

extension Screen {
    /// Lays out the scene's particles and its `weather` for the frame, as `draw(_:at:)` draws them: in one buffer, those
    /// on the ground first, then those standing, by the place among the `entities` (in the order they draw) of where
    /// they came out if the scene is `ySort`, then those in the air; and in each place, those lit before those that glow,
    /// each image's together. `drift` is how far the weather's wind has blown it.
    func lay(_ particles: Particles, weather: Weather?, drift: Vector, among entities: [Entity], keys: [Double]?) -> Laid {
        let (splashes, falling) = weather.map { self.weather($0, drift: drift) } ?? ([], [])
        let catches = weather?.kind == .rain // rain adds the light it catches to what's under it
        let n = particles.count
        guard n > 0 || !splashes.isEmpty || !falling.isEmpty else { return Laid() }
        let places = entities.count + 3, air = entities.count + 2

        // Each kind as it's drawn, and its rank: those lit first, then those that glow, each image's together.
        struct Look {
            let texture: MTLTexture, width: Int, height: Int, columns: Int, frames: Int
            let colors: [UInt32], fade: Bool, glows: Bool, mode: Float, depth: Emitter.Depth
        }
        let looks = particles.kinds.map { kind -> Look in
            let mode: Float = !lit || kind.glows ? 0 : kind.depth == .air ? Lighting.open.rawValue : Lighting.pixel.rawValue
            guard let image = kind.image?.name else {
                return Look(texture: white, width: kind.size, height: kind.size, columns: 1, frames: 1, colors: kind.colors, fade: kind.fade,
                            glows: kind.glows, mode: mode, depth: kind.depth)
            }
            let (texture, frame) = (texture(image), frame(image))
            let columns = max(1, texture.width / max(frame.width, 1)), rows = max(1, texture.height / max(frame.height, 1))
            return Look(texture: texture, width: frame.width, height: frame.height, columns: columns, frames: columns * rows, colors: kind.colors,
                        fade: kind.fade, glows: kind.glows, mode: mode, depth: kind.depth)
        }
        let order = Set(particles.kinds.map { [$0.glows ? "1" : "0", $0.image?.name ?? ""] }).sorted { $0.lexicographicallyPrecedes($1) }
        let rank = particles.kinds.map { kind in order.firstIndex(of: [kind.glows ? "1" : "0", kind.image?.name ?? ""])! }
        let ranks = max(order.count, 1)

        // Where each in view draws, sorted by a count of each place and rank; those out of view are left out.
        // Those standing go among the entities by the entities' keys, their `sortY` in a `ySort` scene, or after them all.
        let (standing, sortYs) = (keys != nil, keys ?? [])
        let (left, top) = (Float(offset.x.rounded(.down)), Float(offset.y.rounded(.down)))
        let (right, bottom) = (left + Float(size.width) + 1, top + Float(size.height) + 1)
        // Read once: in a debug build each read of the particles' arrays is checked, as they can change.
        let (xs, ys, ages, lives, kindOf, depths) = (particles.x, particles.y, particles.age, particles.life, particles.kind, particles.sortY)
        var keys = [Int](repeating: -1, count: n), starts = [Int](repeating: 0, count: places * ranks + 1)
        var shown = 0
        for i in 0..<n {
            let k = kindOf[i], look = looks[k]
            let (x, y) = (xs[i].rounded(.down) - Float(look.width / 2), ys[i].rounded(.down) - Float(look.height / 2))
            guard x + Float(look.width) > left, x < right, y + Float(look.height) > top, y < bottom else { continue }
            let at = switch look.depth {
            case .ground: 0
            case .air: air
            case .standing: 1 + (standing ? place(depths[i], among: sortYs) : entities.count)
            }
            keys[i] = at * ranks + rank[k]
            starts[keys[i] + 1] += 1
            shown += 1
        }
        for key in 1..<starts.count { starts[key] += starts[key - 1] }
        var sorted = [Int](repeating: 0, count: shown)
        for i in 0..<n where keys[i] >= 0 {
            sorted[starts[keys[i]]] = i
            starts[keys[i]] += 1
        }

        // Their instances: each one's corner, width and height in the pass's pixels, its color, its frame's corners in its
        // image, and how it's lit. On the world's whole pixels, the camera taken off, on the canvas's grid, as a sprite's.
        let grid = current?.grid ?? Double(scale)
        var instances: [SIMD4<Float>] = []
        instances.reserveCapacity(shown * 4 + splashes.count + falling.count)
        var runs = [[Laid.Run]](repeating: [], count: places)
        var at = 0
        for here in 0..<places {
            while at < shown, keys[sorted[at]] / ranks == here {
                let (first, key, k) = (instances.count / 4, keys[sorted[at]], kindOf[sorted[at]])
                let look = looks[k]
                let (tw, th) = (Float(look.texture.width), Float(look.texture.height))
                var box = SIMD4<Float>(.infinity, .infinity, -.infinity, -.infinity)
                while at < shown, keys[sorted[at]] == key {
                    let i = sorted[at]
                    let kind = looks[kindOf[i]]
                    let t = min(ages[i] / max(lives[i], 0.0001), 1) // a life of none, put out this update, is over
                    let frame = min(kind.frames - 1, Int(t * Float(kind.frames)))
                    let (u, v) = (Float(frame % kind.columns * kind.width), Float(frame / kind.columns * kind.height))
                    let left = ((Double(xs[i].rounded(.down)) - Double(kind.width / 2) - offset.x) * grid).rounded(.down) / grid
                    let top = ((Double(ys[i].rounded(.down)) - Double(kind.height / 2) - offset.y) * grid).rounded(.down) / grid
                    var color = Particles.color(kind.colors, at: t)
                    if kind.fade { color.w *= 1 - t * t }
                    // Made from their numbers, not array literals, which a debug build makes arrays of for each particle.
                    instances.append(SIMD4(Float(left), Float(top), Float(kind.width), Float(kind.height)))
                    instances.append(color)
                    instances.append(kind.texture === white ? SIMD4(0, 0, 1, 1)
                                                            : SIMD4(u / tw, v / th, (u + Float(kind.width)) / tw, (v + Float(kind.height)) / th))
                    instances.append(SIMD4(kind.mode, 0, 0, 0))
                    box = SIMD4(min(box.x, Float(left)), min(box.y, Float(top)), max(box.z, Float(left) + Float(kind.width)), max(box.w, Float(top) + Float(kind.height)))
                    at += 1
                }
                runs[here].append(Laid.Run(start: first, count: instances.count / 4 - first, texture: look.texture, glows: look.glows, blooms: look.glows,
                                           box: box))
            }
            let weather = here == 0 ? splashes : here == air ? falling : []
            if !weather.isEmpty {
                runs[here].append(Laid.Run(start: instances.count / 4, count: weather.count / 4, texture: white, glows: catches))
                instances += weather
            }
        }
        guard !instances.isEmpty else { return Laid() } // all out of view
        let buffer = device.makeBuffer(bytes: instances, length: instances.count * MemoryLayout<SIMD4<Float>>.stride)
        return Laid(buffer: buffer, runs: runs)
    }

    /// Draws the particles `lay` laid out for `place`: at 0 those on the ground; at 1 + i those standing just behind the
    /// i-th entity in the scene's draw order, and at 1 plus their count those in front of them all; and last, those in
    /// the air. Each run is one instanced draw; a place with none draws nothing, so the quads around it stay one draw.
    /// Those that glow are added to what's under them, lit only if they say, as rain is.
    func draw(_ laid: Laid, at place: Int) {
        guard let buffer = laid.buffer, laid.runs.indices.contains(place), !laid.runs[place].isEmpty else { return }
        flush()
        let (encoder, states) = (self.encoder, particleStates)
        for run in laid.runs[place] {
            let state = run.glows ? states.glowing : states.lit
            if drawing !== state {
                encoder.setRenderPipelineState(state)
                drawing = state
            }
            encoder.setVertexBuffer(buffer, offset: run.start * 4 * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(run.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: run.count)
        }
    }

    /// Rain or snow over the view, and rain's splashes on the ground, as `lay`'s instances: drops in a pattern 256 world
    /// pixels square, repeated across the world, each falling through it again and again as the scene's `time` goes on,
    /// blown along by the wind so far (`drift`), so the view shows the same weather wherever it is and however it got
    /// there. A raindrop comes back down somewhere else each time.
    func weather(_ weather: Weather, drift: Vector) -> (splashes: [SIMD4<Float>], falling: [SIMD4<Float>]) {
        let tile = 256.0, grid = current?.grid ?? Double(scale)
        let (high, low): (Float, Float) = lit ? (Lighting.open.rawValue, Lighting.pixel.rawValue) : (0, 0)
        let (left, top) = (offset.x, offset.y), (right, bottom) = (offset.x + Double(size.width), offset.y + Double(size.height))
        var (splashes, falling): ([SIMD4<Float>], [SIMD4<Float>]) = ([], [])
        func wrapped(_ value: Double) -> Double { value - (value / tile).rounded(.down) * tile }
        // Each copy of a point of the pattern, (x, y), whose `width` by `height` pixels show in the view.
        func put(_ list: inout [SIMD4<Float>], _ x: Double, _ y: Double, _ width: Int, _ height: Int, _ color: SIMD4<Float>, _ mode: Float) {
            let (w, h) = (Double(width), Double(height))
            var across = ((left - w - x) / tile).rounded(.down) + 1
            while x + across * tile < right {
                var down = ((top - h - y) / tile).rounded(.down) + 1
                while y + down * tile < bottom {
                    let (worldX, worldY) = ((x + across * tile).rounded(.down), (y + down * tile).rounded(.down))
                    list.append(SIMD4(Float(((worldX - offset.x) * grid).rounded(.down) / grid), Float(((worldY - offset.y) * grid).rounded(.down) / grid),
                                      Float(width), Float(height)))
                    list.append(color)
                    list.append(SIMD4(0, 0, 1, 1))
                    list.append(SIMD4(mode, 0, 0, 0))
                    down += 1
                }
                across += 1
            }
        }
        let amount = max(weather.amount, 0)
        switch weather.kind {
        case .rain:
            let streak = tint(weather.color, 0.45)
            for i in 0..<Int((amount * 260).rounded()) {
                let fallen = unit(i, 2) * tile + (300 + 80 * unit(i, 3)) * time + drift.y
                let times = (fallen / tile).rounded(.down) // how many times it's fallen through
                put(&falling, wrapped(unit(i &+ Int(times) &* 7919, 1) * tile + drift.x), fallen - times * tile, 1, 4 + Int(unit(i, 4) * 4), streak, high)
            }
            // Splashes: each a pixel where a drop lands, then two spreading from it, every half second or so somewhere else.
            for i in 0..<Int((amount * 70).rounded()) {
                let every = 0.4 + 0.4 * unit(i, 5), since = time + unit(i, 6) * every
                let landed = (since / every).rounded(.down), age = since - landed * every
                guard age < 0.15 else { continue }
                let (x, y, step) = (unit(i &* 131 &+ Int(landed), 7) * tile, unit(i &* 131 &+ Int(landed), 8) * tile, Int(age / 0.05))
                let color = tint(weather.color, 0.4 - 0.1 * Double(step))
                if step == 0 { put(&splashes, x, y, 1, 1, color, low) }
                else {
                    put(&splashes, wrapped(x - Double(step)), y - 1, 1, 1, color, low)
                    put(&splashes, wrapped(x + Double(step)), y - 1, 1, 1, color, low)
                }
            }
        case .snow:
            for i in 0..<Int((amount * 110).rounded()) {
                let sway = sin(time * (0.8 + 1.2 * unit(i, 4)) + unit(i, 5) * 2 * .pi) * (1.5 + 3 * unit(i, 6))
                let x = wrapped(unit(i, 1) * tile + drift.x * (0.7 + 0.6 * unit(i, 7)) + sway)
                let y = wrapped(unit(i, 2) * tile + (12 + 16 * unit(i, 3)) * time + drift.y)
                let size = unit(i, 8) > 0.8 ? 2 : 1
                put(&falling, x, y, size, size, tint(weather.color, 0.7 + 0.3 * unit(i, 9)), high)
            }
        }
        return (splashes, falling)
    }
}

/// The particles' pipelines: those lit, blended by their alpha, and those that glow, added.
struct ParticleStates {
    let lit, glowing: MTLRenderPipelineState

    init(_ library: MTLLibrary, format: MTLPixelFormat) {
        lit = makeState(library, "particleLitFragment", vertex: "particleVertex", formats: [format], rgb: (.sourceAlpha, .oneMinusSourceAlpha),
                        alpha: (.one, .oneMinusSourceAlpha))
        glowing = makeState(library, "particleGlowFragment", vertex: "particleVertex", formats: [format], rgb: (.one, .one), alpha: (.zero, .one))
    }
}

// The particles' shaders. Each particle is an instance of four `float4`s, as `Screen.lay` writes them: its corner, width
// and height in the pass's pixels; its color; its frame's corners in its texture; and how it's lit (Screen.Lighting).
// It's drawn as a quad of six corners.
let particleShaders = """
struct Particle { float4 place; float4 color; float4 uv; float4 more; };

constant float2 particleCorners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 0), float2(1, 1), float2(0, 1) };

vertex Vertex particleVertex(uint i [[vertex_id]], uint n [[instance_id]], constant Particle *p [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
    Particle q = p[n];
    float2 corner = particleCorners[i];
    float2 xy = (q.place.xy + corner * q.place.zw) / size * 2 - 1;
    Vertex out;
    out.position = float4(xy.x, -xy.y, 0, 1);
    out.uv = mix(q.uv.xy, q.uv.zw, corner);
    out.color = q.color;
    out.effects = float4(0, 1, q.more.x, 0);
    out.more = float4(0);
    out.shade = float3(1);
    out.stand = float4(0);
    return out;
}

// A particle that glows, added to what's under it: unlit, but for rain, which adds the light it catches.
fragment float4 particleGlowFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                                     texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    return float4(lit(c.rgb, in.effects.z, float3(1), in.position.xy, view, shadowed, open, clouds) * c.a, c.a);
}

// A particle drawn over what's under it, lit as it says.
fragment float4 particleLitFragment(Vertex in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> shadowed [[texture(1)]],
                                    texture2d<float> open [[texture(2)]], texture2d<float> clouds [[texture(3)]], constant View &view [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float4 c = t.sample(nearest, in.uv) * in.color;
    if (c.a <= 0) discard_fragment();
    return float4(lit(c.rgb, in.effects.z, float3(1), in.position.xy, view, shadowed, open, clouds), c.a);
}

"""
