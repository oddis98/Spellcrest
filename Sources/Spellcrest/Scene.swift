import Foundation
import SpellcrestProtocol
import Synchronization

/// A level, menu or screen: a tilemap plus the entities in it.
@MainActor open class Scene {
    /// The scene on screen. Assign a new one to switch scenes, or a fresh copy to restart.
    public static var current = Scene()

    /// Everything in the scene, in the order it updates and draws.
    public private(set) var entities: [Entity] = []
    /// The level's tiles, drawn behind the entities but for its layers `above` them. `Entity.move(_:)` stops against
    /// its solid ones.
    public var tilemap: Tilemap?
    /// How its world is drawn: its map's projection, flat without one. In an isometric scene, entities stand on their
    /// hitboxes, drawn in front of and behind each other as they stand, and `camera` is in the picture's pixels.
    public var projection: Projection { tilemap?.projection ?? .flat }
    /// Top-left corner of the view, in world pixels; in an isometric scene, in the picture's pixels, where `projection`
    /// draws the world, as particles and bends are.
    public var camera = Vector.zero
    /// An entity the camera keeps in the middle of the view, never showing past the tilemap's edges. A map smaller
    /// than the view sits in the middle of it. It sets `camera` each time the scene draws.
    public var follow: Entity?
    /// Draws the entities from the top of the view down by their `sortY`, their feet, so they pass behind and in front
    /// of each other and of trees and houses: for top-down games. Off, they draw in the order they were added.
    public var ySort = false
    /// Clear color as 0xRRGGBB.
    public var background: UInt32 = 0x1D2B53
    /// How dark the scene is, from 0, lit (the default), to 1, as dark as `darknessColor`, where on black nothing shows
    /// but what its lights light, the entities' `light`s, its `lamps` and its map's tiles that light: for nights, caves
    /// and houses with the lights out. What's drawn after
    /// `super.draw`, like a HUD, stays lit.
    public var darkness = 0.0
    /// The color of the dark, 0xRRGGBB, which multiplies what it darkens: black (the default), or a night's deep blue.
    public var darknessColor: UInt32 = 0x000000
    /// How much of the world's color is drained, from 0, none (the default), to 1, all gray: a memory, a curse.
    public var gray = 0.0
    /// Cloud shadows drifting over the world, shading its daylight; nil, the default, has none.
    public var clouds: Clouds?
    /// Fog over the world, above the entities and under the overhangs, lit as the ground is; nil, the default, has none.
    public var fog: Fog?
    /// How much darker the light gets toward the view's corners, from 0, not at all (the default), to 1: a wood's gloom.
    public var vignette = 0.0
    /// Images behind the map, like a sky or far hills, first to last, each moving at its own rate as the camera moves.
    public var backdrops: [Parallax] = []
    /// Images over the world and its fog, under what's drawn after `super.draw`, like a canopy of leaves hanging over the
    /// view, first to last.
    public var overhangs: [Parallax] = []
    /// The game's layer shaders, from `Assets/Shaders`, run on the picture in turn after the world and its overhangs and
    /// before what's drawn after `super.draw`: a ripple, a heat haze, a wobble. Each draws once it has compiled, over the
    /// whole canvas, so `bends` cost less where they'll do.
    public var effects: [Shader] = []
    /// Its particles: sparks, embers, smoke and motes, put out by its entities' `emitter`s and by
    /// `particles.burst(_:at:count:angle:sortY:)`, moved with its updates and drawn with its world.
    public let particles = Particles()
    /// Rain or snow falling over its world; nil, the default, has none.
    public var weather: Weather?
    /// A bloom of what glows in its world, spreading past its pixels into the dark around it, and of light past daylight;
    /// nil, the default, has none.
    public var bloom: Bloom?
    /// Where the air bends the picture this frame, around points in the world: rings going out where spells land, heat
    /// haze, swirls. Set them in the scene's updates as what bends the air moves and changes; drawn after the bloom and
    /// before the `effects`.
    public var bends: [Bend] = []
    /// How its lit sprites and tiles show which side their light is on: by normal maps beside their images, or by a rim
    /// on sprites' edges facing it. None, the default, lights them as before.
    public var shaping: Shaping = []
    /// Lights where there's no entity: a torch on a wall, a flash where a spell lands. Its map's tiles that light are lit
    /// as these are (`Tilemap.lamps`).
    public var lamps: [Lamp] = []
    /// How fast its world goes: 1, the default, as it is; 0 holds it still for the few updates a hit lands; 0.3 slows it
    /// to a crawl as a fight's last foe falls. Its entities (their `update` gets `dt` times it), their sprites' and lights'
    /// time, their emitters, its tiles, its particles, its lamps, its weather, and the clock its clouds, fog, swaying
    /// and shaders go by, all go by it. Its own `update` still gets the real `dt`, so it can count down a hold and read
    /// the buttons, and slows what it moves itself by this; the view's shake and a transition keep real time too, so a
    /// hit's shake plays out while its hold keeps the rest still; and what's drawn after `super.draw` is the game's.
    public var timeScale = 1.0
    var drift = Vector.zero // how far the weather's wind has blown it
    var clock = 0.0 // seconds the scene's world has gone, by its `timeScale`: clouds, fog, swaying, shaders
    var shook = 0.0 // seconds the scene has updated, in real time, which the shake wobbles by
    var shaking = Shake()
    var added = 0 // entities added so far, which numbers each, for its light's flicker

    /// An empty scene, to subclass: set up its map and entities in your `init()`, then call super's.
    public init() {}

    /// Shakes the view, not what's drawn after `super.draw`: `trauma` from 0 to 1 is added to what's left, and decays
    /// over about a second, moving the view up to 8 pixels times its square: 0.3 for a thud, 1 for lightning striking.
    public func shake(_ trauma: Double) { shaking.add(trauma) }

    /// How far the shake moves the view now, in pixels: the world is drawn with its top-left corner at `camera` plus
    /// this. What a game places on the view by `camera`, like a layer shader's position or a HUD over an entity, takes
    /// it off too to stay with the world as it shakes: `Shader(.ripple, [x - camera.x - shakeOffset.x, …])`.
    public var shakeOffset: Vector { shaking.offset(at: shook) }

    /// Switches to `next` through `color`: this scene stands still while the view fades to the color over the first
    /// half of `duration` seconds, then `next` becomes `current` and updates while it fades back in. It's
    /// `transition(to:duration:style:color:)`'s fade.
    public static func fade(to next: Scene, duration: Double = 0.5, color: UInt32 = 0x000000) {
        transition(to: next, duration: duration, style: .fade, color: color)
    }

    /// Switches to `next` over `duration` seconds in a `style`: a fade, a wipe or an iris goes through `color`, this
    /// scene standing still until the color covers the view, halfway, then `next` becoming `current` and updating as
    /// it's uncovered; a dissolve has `next` update from the start, under this scene's last frame as it breaks up. A
    /// transition covers everything, a HUD too, and pauses with the game. `Scene.current = next` switches at once. One
    /// started while another is under way takes its place from as far as the view is covered, so a fade started as
    /// another uncovers the view darkens it again from there, rather than jumping to all of it showing.
    public static func transition(to next: Scene, duration: Double = 0.5, style: Transition = .fade, color: UInt32 = 0x000000) {
        guard duration > 0 else { return current = next }
        var change = Change(next: next, duration: duration, style: style, color: color, old: current)
        if let under = changing, under.style != .dissolve, style != .dissolve { change.time = under.cover * duration / 2 }
        changing = change
    }

    /// The transition under way, if any.
    static var changing: Change?

    /// Tells the scene, and those a transition is between, each once, that the canvas changed size from `old`.
    static func resized(from old: Size) {
        var told: [Scene] = []
        for scene in [current, changing?.next, changing?.old].compactMap({ $0 }) where !told.contains(where: { $0 === scene }) {
            scene.resized(from: old)
            told.append(scene)
        }
    }

    /// One update of the game: the current scene's, unless it's standing still for a transition.
    static func tick(_ dt: Double) {
        for entity in current.entities { entity.before = entity.position + entity.remainder } // where `drawnAt` goes on from
        guard var change = changing else { return current.advance(dt) }
        change.time += dt
        if let next = change.next, change.time >= change.switchTime { (current, change.next) = (next, nil) }
        changing = change.time < change.duration ? change : nil
        if change.next == nil { current.advance(dt) }
    }

    /// An update, and the scene's time and shake with it, whether or not the game calls super: its world's by its
    /// `timeScale`, the shake's and its own update's in real time.
    func advance(_ dt: Double) {
        let scaled = dt * max(0, timeScale)
        clock += scaled
        shook += dt
        shaking.decay(dt)
        particles.update(scaled) // first, so what an update puts out is drawn where it came out
        if let weather { drift += weather.wind * scaled }
        update(dt)
    }

    /// Puts an entity in the scene with its top-left corner at `position`, in world pixels.
    public func add(_ entity: Entity, at position: Vector) {
        entity.position = position
        entity.scene = self
        entity.number = added
        added += 1
        entities.append(entity)
    }

    /// Takes an entity out of the scene, even from its own `update`.
    public func remove(_ entity: Entity) {
        entities.removeAll { $0 === entity }
        entity.scene = nil
    }

    /// Adds the tilemap's objects that are things in the world and returns them: each one whose definition names a
    /// class, made as that class (a `Placeable`), or that has sprites, as an `Entity`. Zones and markers stay in
    /// `tilemap.objects` for the game to read, like a door to step on or where the player starts.
    @discardableResult public func addObjects() -> [Entity] {
        (tilemap?.objects ?? []).compactMap { object in
            guard object.class != nil || object.sprite != nil || !object.parts.isEmpty else { return nil }
            let entity = Self.make(object)
            add(entity, at: object.position)
            return entity
        }
    }

    /// Makes the object `name` from its definition, `Assets/Objects/<name>.object`, as `addObjects()` makes a map's,
    /// as if placed at `position` with `properties` of its own over the definition's, and adds it: something the player
    /// builds, or a creature that comes out at night.
    @discardableResult public func add(_ name: ObjectName, at position: Vector, properties: [String: String] = [:]) -> Entity {
        add(name.name, at: position, properties: properties)
    }

    /// The same, with the object named in a string, like a den's `creature`. Without a definition it's an empty
    /// `Entity`, and the console says why, once.
    @_disfavoredOverload @discardableResult
    public func add(_ name: String, at position: Vector, properties: [String: String] = [:]) -> Entity {
        let entity = make(name, at: position, properties: properties)
        add(entity, at: position)
        return entity
    }

    /// Makes the object `name` from its definition as `add(_:at:properties:)` does, as its class, without adding it:
    /// to read what it would be before it's there, like the sprite of a building the player is about to put down.
    public func make(_ name: ObjectName, at position: Vector, properties: [String: String] = [:]) -> Entity {
        make(name.name, at: position, properties: properties)
    }

    /// The same, with the object named in a string.
    @_disfavoredOverload public func make(_ name: String, at position: Vector, properties: [String: String] = [:]) -> Entity {
        let placed = TilemapFile.Object(name: name, x: Int(position.x), y: Int(position.y), properties: properties)
        return Self.make(Tilemap.Object(placed, definition: Self.definition(name), tileSize: tilemap?.tileSize ?? 16, projection: projection, frame: frameSize))
    }

    /// `Assets/Objects/<name>.object`, read `once`; nil if it can't be, which the console says, once.
    static func definition(_ name: String) -> ObjectFile? {
        once(name, in: definitionsRead) {
            let url = assetURL("\(name).object")
            do { return try ObjectFile(contentsOf: url) } catch {
                if warned.insert("\(name).object").inserted { print("Spellcrest: can't make \(name) from \(url.path): \(error.localizedDescription)") }
                return nil
            }
        }
    }

    /// In an app, reads every object's definition, and the size of its sprite's frames, in the background as the game
    /// starts, so making one in code, like a creature that comes out at night, reads no file on the main thread: the
    /// first boar took 4 ms on an iPhone.
    nonisolated static func readAhead() {
        guard !assetsCanChange else { return }
        DispatchQueue.global(qos: .utility).async {
            for name in bundledNames(["object"]) {
                guard let definition = try? ObjectFile(contentsOf: assetURL("\(name).object")) else { continue } // said as it's made
                definitionsRead.withLock { if $0[name] == nil { $0[name] = definition } }
                if let sprite = definition.sprite { _ = frameSize(sprite) }
            }
        }
    }

    /// The game's module, for finding its classes by name; `Game.main()` sets it.
    static var module = ""
    static var warned: Set<String> = [] // classes and objects the console said something about

    /// An object made as its class, or as an `Entity` if it names none, or one that's missing or isn't `Placeable`
    /// (the console says why, once).
    static func make(_ object: Tilemap.Object) -> Entity {
        guard let name = object.class else { return Entity(object) }
        let found: AnyClass? = NSClassFromString(name.contains(".") ? name : "\(module).\(name)")
        if let type = found as? any Placeable.Type { return type.init(object) }
        if warned.insert(name).inserted {
            print(found == nil ? "Spellcrest: \(object.name).object names the class \(name), which \(module) doesn't have, so it's an Entity"
                               : "Spellcrest: \(name) isn't Placeable, so \(object.name) is an Entity. Mark it: final class \(name): Entity, Placeable")
        }
        return Entity(object)
    }

    /// Runs 60 times a second, `dt` the real time since the last. Call super to update the entities and put out their
    /// emitters' particles, by the scene's `timeScale`.
    /// Called on an iPhone or iPad when the display the game is on changes, and as the game's view is first laid out: it
    /// turned, a foldable opened, or the room the system needs, its safe area, moved; and the game gave the canvas for it
    /// (`Game.resolution(for:)`). Lay out again what was placed for the old shape. `old` is the canvas's size before, the
    /// same if only the room round it changed, and `Input.canvas` its size now. It does nothing unless the scene says
    /// otherwise.
    open func resized(from old: Size) {}

    open func update(_ dt: Double) {
        let dt = dt * max(0, timeScale)
        for entity in entities {
            entity.update(dt)
            if let speed = entity.sprite?.speed { entity.sprite?.time += dt * speed }
            for i in entity.parts.indices {
                let speed = entity.parts[i].sprite.speed
                entity.parts[i].sprite.time += dt * speed
            }
            entity.light?.time += dt
            if let emitter = entity.emitter, emitter.rate > 0, entity.scene === self {
                entity.emitted += emitter.rate * dt
                guard entity.emitted >= 1 else { continue }
                let due = Int(entity.emitted)
                entity.emitted -= Double(due)
                particles.burst(emitter, at: entity.position + entity.remainder + entity.middleOffset, count: due, sortY: entity.sortY)
            }
        }
        for i in lamps.indices { lamps[i].light.time += dt }
        tilemap?.time += dt
    }

    /// Call super to draw the world, then draw anything on top (like a HUD) in screen pixels. The world is its backdrops,
    /// its tilemap, its particles on the ground and rain's splashes, its entities among its particles standing, the map's
    /// layers above and the entities' parts above, its particles in the air and its rain or snow, in that order, then its
    /// fog and its overhangs, lit by its light (`darkness` and the entities' `light`s, `clouds`, `vignette` and `gray`),
    /// then its `bloom`, its `bends` and its `effects`. What's drawn after it stays lit.
    open func draw(_ screen: Screen) {
        let isometric = projection == .isometric
        for entity in entities { entity.place(screen.alpha) }
        if isometric { // the walls of the room the followed entity's in, cut open
            let inside = follow.flatMap { room(under: $0.footprintMiddle) }
            for entity in entities { entity.cut = inside != nil && entity.object?.text("room") == inside }
        }
        // In an isometric scene, how each stands, which also says where its sprite is drawn, so it's worked out first.
        let stood = isometric ? isometricOrder(screen) : nil
        let order = stood?.entities ?? drawOrder, keys = stood?.keys ?? (ySort ? order.map(\.sortY) : nil)
        for entity in entities where entity.emitter != nil { // where its particles come out
            entity.shown = (isometric ? entity.pictureMiddle(screen) : screen.middle(of: entity)) - entity.drawnAt
        }
        if let follow, isometric, let map = tilemap {
            camera = Self.camera(following: follow.pictureMiddle(screen), view: screen.size, map: map.picture)
        } else if let follow {
            let middle = follow.drawnAt + [Double(follow.hitbox.x + follow.hitbox.width / 2), Double(follow.hitbox.y + follow.hitbox.height / 2)]
            camera = Self.camera(following: middle, view: screen.size, map: tilemap?.size)
        }
        screen.time = clock - (1 - screen.alpha) * Loop.step * max(0, timeScale) // between updates, as the entities are
        screen.offset = camera + shaking.offset(at: shook - (1 - screen.alpha) * Loop.step)
        (screen.blooming, screen.glowed, screen.shaping) = (bloom != nil, [], shaping) // what glows is kept for the bloom as it's drawn
        let tiles: [Shine] = tilemap.map { map in
            map.lamps.enumerated().map { i, lamp in // flickering with the map's time, each as its own
                var light = lamp.light
                light.time = map.time
                return Shine(middle: lamp.position + light.offset, radius: light.radius(seed: 2000 + i), light: light)
            }
        } ?? []
        let shines = entities.compactMap { entity in
            let middle = isometric ? entity.footprintMiddle : screen.middle(of: entity) // an isometric scene's lights lie on its floor
            return entity.light.map { Shine(middle: middle + $0.offset, radius: $0.radius(seed: entity.number), light: $0) }
        } + lamps.enumerated().map { i, lamp in
            Shine(middle: lamp.position + lamp.light.offset, radius: lamp.light.radius(seed: 1000 + i), light: lamp.light)
        } + tiles
        if isometric { // as the picture shows the floor, under what stands as far down as it reaches up from below the view
            let tallest = Int((stood?.stands.map(\.height).max() ?? 0).rounded(.up))
            let rise = (min(tallest, screen.size.height) + 31) / 32 * 32 // in steps, so the maps aren't made again as it changes
            screen.light(self, shines.map { Shine(middle: projection.picture(of: $0.middle), radius: $0.radius, light: $0.light) }, below: rise)
        } else {
            screen.light(self, shines)
        }
        func lit(_ lighting: Screen.Lighting, standing entity: Entity? = nil, at place: Int = 0) {
            screen.lighting = screen.lit ? lighting : .none
            if let stands = stood?.stands, entity != nil {
                let s = stands[place]
                screen.stand = SIMD4(Float(s.footprint.z), Float(s.footprint.w), Float(s.height), 0)
            } else if let entity {
                screen.feet = entity.drawnAt + [Double(entity.hitbox.x) + Double(entity.hitbox.width) / 2, Double(entity.hitbox.y + entity.hitbox.height) - 0.5]
            }
        }
        lit(.daylight)
        for backdrop in backdrops { screen.draw(backdrop) }
        lit(.pixel)
        if let tilemap { screen.draw(tilemap, layers: tilemap.layers.indices.filter { !tilemap.above.contains($0) }) }
        let standing: Screen.Lighting = isometric ? .raised : ySort ? .standing : .pixel
        let blown = drift - (weather?.wind ?? .zero) * (1 - screen.alpha) * Loop.step * max(0, timeScale) // between updates, as the time is
        let laid = screen.lay(particles, weather: weather, drift: blown, among: order, keys: keys)
        screen.draw(laid, at: 0) // on the ground
        for (i, entity) in order.enumerated() {
            screen.draw(laid, at: 1 + i) // standing behind it
            lit(standing, standing: entity, at: i)
            entity.draw(screen)
        }
        screen.draw(laid, at: 1 + order.count) // standing in front of every entity
        lit(.open)
        if let tilemap, !tilemap.above.isEmpty { screen.draw(tilemap, layers: tilemap.above.sorted()) }
        for (i, entity) in order.enumerated() {
            lit(standing, standing: entity, at: i)
            entity.draw(screen, above: true)
        }
        screen.draw(laid, at: 2 + order.count) // in the air
        if let fog { screen.draw(fog) }
        lit(.daylight)
        for overhang in overhangs { screen.draw(overhang) }
        screen.lighting = .none
        screen.bloom(bloom, laid)
        screen.bend(bends)
        screen.apply(effects)
        (screen.offset, screen.shaping) = (.zero, [])
    }

    /// The order an isometric scene's entities draw in, each after those behind it that it overlaps in the picture, and
    /// where its particles standing draw among them: after each entity whose footprint's middle is further up the
    /// picture than they are, or one before it in the order.
    func isometricOrder(_ screen: Screen) -> (entities: [Entity], keys: [Double], stands: [Standing]) {
        let standing = entities.map { $0.standing { image in screen.frame(image) } }
        let order = Spellcrest.isometricOrder(standing)
        var keys = order.map { standing[$0].nearness / 2 } // the picture's y at each footprint's middle
        for i in keys.indices.dropFirst() { keys[i] = max(keys[i], keys[i - 1]) } // never back up, for particles to find their place
        return (order.map { entities[$0] }, keys, order.map { standing[$0] })
    }

    /// The order the entities draw in: as they were added, or with `ySort` by `sortY`, ties as they were added.
    var drawOrder: [Entity] {
        guard ySort else { return entities }
        return entities.enumerated().sorted { ($0.element.sortY, $0.offset) < ($1.element.sortY, $1.offset) }.map(\.element)
    }

    /// The camera that puts `middle` in the middle of a `view`, kept inside a `map` of that size, or in the middle of a
    /// map smaller than the view. Between pixels as the entity it follows is, so the two move together.
    nonisolated static func camera(following middle: Vector, view: Size, map: Size?) -> Vector {
        camera(following: middle, view: view, map: map.map { Rect(x: 0, y: 0, width: $0.width, height: $0.height) })
    }

    /// The same, for a map that covers `map` of the picture, as an isometric one does, from left of 0.
    nonisolated static func camera(following middle: Vector, view: Size, map: Rect?) -> Vector {
        func axis(_ middle: Double, _ view: Int, _ start: Int?, _ map: Int?) -> Double {
            guard let start, let map else { return middle - Double(view / 2) }
            return Double(start) + (map < view ? Double((map - view) / 2) : min(max(middle - Double(start) - Double(view / 2), 0), Double(map - view)))
        }
        return [axis(middle.x, view.width, map?.x, map?.width), axis(middle.y, view.height, map?.y, map?.height)]
    }
}

/// How `Scene.transition(to:duration:style:color:)` goes from one scene to the next.
public enum Transition: Sendable, Equatable {
    /// The view fades to the color and back.
    case fade
    /// The color sweeps over the view from a side, then on off the other, the next scene coming in behind it.
    case wipe(from: Side)
    /// The view closes to the color in a circle around the entity the camera follows (`Scene.follow`), or the middle
    /// of the view, then opens around the next scene's.
    case iris
    /// The scene breaks up into the next one, its pixels going in a pattern, with no color between them.
    case dissolve

    /// Where a wipe comes in.
    public enum Side: Sendable {
        /// From the left edge, going on off the right.
        case left
        /// From the right edge, going on off the left.
        case right
        /// From the top, going on off the bottom.
        case top
        /// From the bottom, going on off the top.
        case bottom
    }
}

/// A switch to another scene under way, from `Scene.transition(to:duration:style:color:)`.
struct Change {
    var next: Scene? // until the switch
    let duration: Double
    let style: Transition
    let color: UInt32
    var old: Scene? // the scene it leaves, which a dissolve draws once more for its copy, then lets go
    var time = 0.0
    var snapped = false // a dissolve's copy of the scene it leaves, taken as it draws first

    /// When `next` becomes current: once the color covers the view, halfway, or for a dissolve at once.
    var switchTime: Double { style == .dissolve ? 0 : duration / 2 }

    /// How much the color covers: from none to all of the view at the switch, then back. A fade's opacity.
    var cover: Double { max(0, 1 - abs(time / duration * 2 - 1)) }

    /// How much of the old scene a dissolve keeps: all of it, then none.
    var kept: Double { max(0, 1 - time / duration) }

    /// What a wipe from `side` covers: growing from that side until the switch, then shrinking off the other.
    func wiped(from side: Transition.Side, view: Size) -> Rect {
        let across = side == .left || side == .right
        let length = across ? view.width : view.height
        let covered = Int((cover * Double(length)).rounded())
        var start = time < duration / 2 ? 0 : length - covered // from the side it comes in at
        if side == .right || side == .bottom { start = length - start - covered }
        return across ? Rect(x: start, y: 0, width: covered, height: view.height) : Rect(x: 0, y: start, width: view.width, height: covered)
    }

    /// The radius of an iris around `center`, in canvas pixels: from the view's farthest corner to nothing at the
    /// switch, then back.
    func radius(around center: Vector, view: Size) -> Double {
        let (width, height) = (Double(view.width), Double(view.height))
        let corners: [Vector] = [[0, 0], [width, 0], [0, height], [width, height]]
        return corners.map { (($0 - center) * ($0 - center)).sum().squareRoot() }.max()! * (1 - cover)
    }

    /// Draws it over everything the scene drew: the color, or the old scene's last frame breaking up.
    @MainActor func draw(_ screen: Screen, over scene: Scene) {
        let view = screen.size
        screen.offset = .zero
        switch style {
        case .fade:
            screen.fill(Rect(x: 0, y: 0, width: view.width, height: view.height), color: color, opacity: cover)
        case let .wipe(side):
            screen.fill(wiped(from: side, view: view), color: color)
        case .iris:
            let center = scene.follow.map { screen.middle(of: $0) - scene.camera } ?? [Double(view.width) / 2, Double(view.height) / 2]
            let radius = radius(around: center, view: view)
            for y in 0..<view.height { // the row's pixels left and right of the circle
                let dy = Double(y) + 0.5 - center.y
                let half = radius > abs(dy) ? (radius * radius - dy * dy).squareRoot() : 0
                let (left, right) = (Int((center.x - half).rounded()), Int((center.x + half).rounded()))
                screen.fill(Rect(x: 0, y: y, width: min(max(left, 0), view.width), height: 1), color: color)
                screen.fill(Rect(x: max(right, 0), y: y, width: view.width - min(max(right, 0), view.width), height: 1), color: color)
            }
        case .dissolve:
            screen.whole(screen.snapshot, keep: kept)
        }
    }
}

/// Anything that lives in a scene: the player, enemies, pickups.
@MainActor open class Entity {
    /// Top-left corner, in world pixels. In an isometric scene, a point on the floor, which its hitbox is from.
    public var position = Vector.zero
    /// Pixels per second, applied by `move(_:)`.
    public var velocity = Vector.zero
    /// The solid part of the entity, relative to `position`. In an isometric scene, its footprint on the floor, which its
    /// sprite stands on (`spriteAt`).
    public var hitbox = Rect(x: 0, y: 0, width: 16, height: 16)
    /// What it looks like, drawn at `drawnAt`; nil draws nothing.
    public var sprite: Sprite?
    /// More sprites it's drawn with, each at an offset: a tree's crown, a house's roof, a hat. Those `above` draw over
    /// every entity, as a roof the player walks under does; the rest draw with it, after `sprite`.
    public var parts: [Part] = []
    /// Blocks other entities' `move(_:)`, as solid tiles do: villagers, chests, tree trunks.
    public var solid = false
    /// Its hitbox stops the light of a `Light` with shadows, as a tileset's opaque tiles do: tree trunks, pillars, a cart.
    public var opaque = false
    /// The scene it's in, from `Scene.add(_:at:)`.
    public internal(set) weak var scene: Scene?
    /// The map's object it was made from, for its properties. It's set after `init()` runs, so read it in a `lazy var`:
    /// `lazy var speed = object?.double("speed") ?? 40`.
    public var object: Tilemap.Object?
    /// The light it gives off, from its middle: a torch's in the dark, a gloom's; nil gives none.
    public var light: Light?
    /// The particles it gives off, `rate` a second, from its middle as its light shines: a torch's flame, a spell's
    /// trail, a gloom's motes; nil gives none. They go on without it once they're out, so a trail stays where it was left.
    public var emitter: Emitter?
    /// How deep a corner can be, in pixels, for `move(_:)` to nudge the entity around it instead of stopping: going
    /// straight left, right, up or down into something that catches no more of its hitbox than that, it slides sideways
    /// past, as top-down games since Zelda do. About 4 for a top-down game's player. 0, the default, stops it flush, as
    /// a platformer wants: its player would slip off a ledge it lands on by a few pixels.
    public var cornerSlide = 0
    var remainder = Vector.zero // sub-pixel movement not applied yet
    /// Where it's drawn this frame, in world pixels: `position` and the part of a pixel `move(_:)` has moved it but not
    /// yet applied, and on a display faster than 60 frames a second, part of the way there from where it was at the last
    /// update. Its sprite, parts and light draw from here and the camera follows it; draw what goes with it from here too.
    public var drawnAt: Vector { position + between }
    var between = Vector.zero // from `position` to where it's drawn, worked out by the scene for each frame (`place`)
    var before: Vector? // `position + remainder` as the last update started (`Scene.tick`)
    var number = 0 // its place among what its scene has added, which sets its light's flicker apart, the same each run
    var emitted = 0.0 // the part of a particle its emitter has put out but not yet let go
    var shown: Vector? // from `drawnAt` to its middle, as the scene last drew it
    var pictured: Vector? // where its sprite was drawn in an isometric picture this frame (`spriteAt`)
    var cut = false // a wall of the room the scene's followed entity is in, drawn cut (`drawnSprite`)

    /// From its position to its middle, where its emitter's particles come out: as it was last drawn, or before that,
    /// its sprite's frame's middle, or its hitbox's without one.
    var middleOffset: Vector {
        if let shown { return shown }
        if let sprite, let frame = frameSize(sprite.image) { return [Double(frame.width), Double(frame.height)] / 2 }
        return [Double(hitbox.x) + Double(hitbox.width) / 2, Double(hitbox.y) + Double(hitbox.height) / 2]
    }

    /// An entity at (0, 0) with a 16×16 hitbox and no sprite, to subclass: set its sprite, hitbox and the rest in your
    /// `init()`.
    public init() {}

    /// Works out where it's drawn in a frame `alpha` of the way from the last update to the next: that far from where it
    /// was as the update started to where it is, or there at once after a jump of more than 8 pixels, like a door, or
    /// when it was added since.
    func place(_ alpha: Double) {
        let now = position + remainder
        guard let before, alpha < 1, Swift.max(abs(now.x - before.x), abs(now.y - before.y)) <= 8 else { return between = remainder }
        between = before + (now - before) * alpha - position
    }

    /// Makes an entity from an object placed in a map, as `Scene.addObjects()` does: `init()` runs, then it takes the
    /// object's place, hitbox, solidity and opacity, and its sprites if it has any, and keeps the object in `object`. The
    /// object's sprite keeps what `init()` set on the one it takes the place of that the object editor has no field for:
    /// whether it glows, its shader, color, opacity and whether it's flipped. A subclass that overrides `init()`, or
    /// declares no initializers, inherits this.
    public convenience init(_ object: Tilemap.Object) {
        self.init()
        (self.object, position, hitbox, solid, opaque) = (object, object.position, object.hitbox, object.solid, object.opaque)
        if var sprite = object.sprite {
            if let made = self.sprite {
                (sprite.glows, sprite.shader, sprite.color, sprite.opacity, sprite.flipped) = (made.glows, made.shader, made.color, made.opacity, made.flipped)
            }
            self.sprite = sprite
        }
        if !object.parts.isEmpty { parts = object.parts }
    }

    /// A sprite an entity is drawn with besides its `sprite`.
    public struct Part: Sendable {
        /// What it draws, which animates as the entity's sprite does.
        public var sprite: Sprite
        /// From the entity's `position`, in pixels.
        public var offset: Vector
        /// Draws over every entity, and over the map's layers above them.
        public var above: Bool

        /// A part drawing `sprite` at `offset` from the entity's top-left corner, over everything if it's `above`, like
        /// a tree's crown.
        public init(_ sprite: Sprite, offset: Vector = .zero, above: Bool = false) { (self.sprite, self.offset, self.above) = (sprite, offset, above) }
    }

    /// Runs 60 times a second; `dt` is the time since the last update, in seconds. Override it to move and react.
    open func update(_ dt: Double) {}

    /// Draws the sprite and the parts that aren't above. Override it to draw more, in world pixels, and call super to
    /// keep them; in an isometric scene, in the picture's pixels, from `spriteAt`.
    open func draw(_ screen: Screen) {
        if let sprite = drawnSprite { screen.draw(sprite, x: spriteAt.x, y: spriteAt.y) }
        draw(screen, above: false)
    }

    /// Draws the parts that are, or aren't, above: the scene draws those above after the rest.
    func draw(_ screen: Screen, above: Bool) {
        let corner = spriteAt
        for part in parts where part.above == above {
            screen.draw(part.sprite, x: corner.x + part.offset.x, y: corner.y + part.offset.y)
        }
    }

    /// Where it draws when the scene's `ySort` is on, in world pixels: the bottom of its hitbox, its feet, so the
    /// hitbox of a tree is its trunk. Override it for something always under the rest, like a shadow (`-.infinity`),
    /// or over it, like a bird.
    /// In an isometric scene, where particles go among what stands there: as far down the picture as its footprint's
    /// middle is on the floor, what `particles.burst(_:at:count:angle:sortY:)` takes to draw sparks in front of it.
    open var sortY: Double { scene?.projection == .isometric ? pictureDepth : Double(box(at: position).y + hitbox.height) }

    /// Moves by `velocity * dt` one pixel at a time, stopping flush against solid tiles and solid entities (but not
    /// those it already overlaps, so two that start on top of each other can walk apart), or with `cornerSlide` sliding
    /// around their corners. Hitting something zeroes that part of the velocity. Along an axis it has no velocity on,
    /// it stays where it is, though it stopped part of a pixel into a step.
    public func move(_ dt: Double) {
        let straight = velocity.x == 0 || velocity.y == 0 // only that slides around corners, not a diagonal
        remainder += velocity * dt
        var pixels = remainder.rounded(.toNearestOrAwayFromZero)
        // Standing still, what's left of a pixel would round to one, then back the next update, and on: it waits instead.
        for axis in 0..<2 where velocity[axis] == 0 { pixels[axis] = 0 }
        remainder -= pixels
        for axis in 0..<2 where !slide(Int(pixels[axis]), axis: axis, aroundCorners: straight) {
            velocity[axis] = 0
            remainder[axis] = 0
        }
    }

    /// The middle of its hitbox, in whole world pixels: where it walks from and to on a path, and where another
    /// entity heads to reach it: `enemy.path(to: player.middle)`.
    public var middle: Vector {
        let box = box(at: position)
        return [Double(box.x + box.width / 2), Double(box.y + box.height / 2)]
    }

    /// The way to `point`, in world pixels, around the map's solid tiles and the scene's other solid entities: the
    /// middle of each cell of the map to walk through, from the one after the cell its `middle` is in to the one
    /// `point` is in, for `walk(_:along:speed:)`. Steps go to a cell beside, above or below, or with `diagonals` to one
    /// at a corner too, but never past the corner of a cell that's in the way. Nil when there's no way there: `point`
    /// is in a solid tile, either is off the map, or there's no tilemap. A cell is in the way when a solid entity is
    /// in it, but for the one `point` is in, so the way can lead to another entity, like a solid player being chased.
    /// A hitbox no bigger than a tile, walked by its middle, fits through every cell on the way.
    public func path(to point: Vector, diagonals: Bool = false) -> [Vector]? {
        guard let scene, let map = scene.tilemap else { return nil }
        let (size, goal) = (map.tileSize, map.cell(at: point))
        var taken: Set<SIMD2<Int>> = [] // cells solid entities are in
        for other in scene.entities where other.solid && other !== self {
            let box = other.box(at: other.position)
            for row in stride(from: map.cell(box.y), through: map.cell(box.y + box.height - 1), by: 1) {
                for column in stride(from: map.cell(box.x), through: map.cell(box.x + box.width - 1), by: 1) { taken.insert([column, row]) }
            }
        }
        taken.remove(goal)
        let cells = map.route(from: map.cell(at: middle), to: goal, diagonals: diagonals) { cell in
            !taken.contains(cell) && !map.isSolid(Rect(x: cell.x * size, y: cell.y * size, width: size, height: size))
        }
        return cells?.map { [Double($0.x * size + size / 2), Double($0.y * size + size / 2)] }
    }

    /// Walks along `path`, points in world pixels like those `path(to:)` finds, at `speed` pixels a second: heads for
    /// the first until its `middle` is there, takes it off and heads for the next, and stops, its velocity zero, once
    /// there are none. It moves as `move(_:)` does, so something solid in the way holds it up until it's gone. Call it
    /// in each update instead of `move(_:)`: `walk(dt, along: &route, speed: 40)`.
    public func walk(_ dt: Double, along path: inout [Vector], speed: Double) {
        func reached(_ point: Vector) -> Bool { ((point - middle) * (point - middle)).sum() < 1 } // within a pixel
        while let point = path.first, reached(point) { path.removeFirst() }
        guard let point = path.first else { return velocity = .zero }
        let way = point - middle, distance = (way * way).sum().squareRoot()
        if distance <= speed * dt { (velocity, remainder) = (way / dt, .zero) } // there in this update, not past it
        else { velocity = way / distance * speed }
        move(dt)
        guard reached(point) else { return }
        path.removeFirst()
        if path.isEmpty { velocity = .zero }
    }

    /// Standing on a solid tile or entity.
    public var onGround: Bool { blocked(at: position + [0, 1]) }

    /// True when the two hitboxes overlap.
    public func overlaps(_ other: Entity) -> Bool { box(at: position).intersects(other.box(at: other.position)) }

    /// True when the hitbox overlaps `box`, in world pixels, like a door's from `Tilemap.Object.box`.
    public func overlaps(_ box: Rect) -> Bool { self.box(at: position).intersects(box) }

    /// True when `point`, in world pixels, is in the hitbox, like the pointer plus the scene's camera:
    /// `if Input.pressed(.pointer), let point = Input.pointer, chest.contains(point + camera)`.
    public func contains(_ point: Vector) -> Bool { box(at: position).contains(point) }

    /// Moves `pixels` along `axis` (0 for x, 1 for y) a pixel at a time, or around a corner a pixel sideways for each
    /// pixel it's held up; false once it can do neither.
    func slide(_ pixels: Int, axis: Int, aroundCorners: Bool) -> Bool {
        let step = Double(pixels.signum())
        for _ in 0..<abs(pixels) {
            var next = position
            next[axis] += step
            if !blocked(at: next) {
                position = next
            } else if aroundCorners, let side = side(around: axis, step) {
                position[1 - axis] += side
            } else {
                return false
            }
        }
        return true
    }

    /// Which way across `axis`, -1 or 1, it gets past what holds it up going `step` along it, by moving no more than
    /// `cornerSlide` pixels sideways first, the nearer way if both do; nil if neither does, as at a wall.
    func side(around axis: Int, _ step: Double) -> Double? {
        var sides: [Double] = [-1, 1]
        for depth in stride(from: 1.0, through: Double(cornerSlide), by: 1) {
            for side in sides {
                var aside = position
                aside[1 - axis] += side * depth
                if blocked(at: aside) { // a wall that way too
                    sides.removeAll { $0 == side }
                    continue
                }
                aside[axis] += step
                if !blocked(at: aside) { return side }
            }
        }
        return nil
    }

    /// Whether a solid tile, or a solid entity it doesn't overlap already, is in the way at `position`.
    // ponytail: scans every entity each pixel step; a grid of cells when a level holds thousands of solid things
    func blocked(at position: Vector) -> Bool {
        let (box, here) = (box(at: position), box(at: self.position))
        if scene?.tilemap?.isSolid(box) == true { return true }
        return scene?.entities.contains { other in
            guard other.solid, other !== self else { return false }
            let theirs = other.box(at: other.position)
            return theirs.intersects(box) && !theirs.intersects(here)
        } ?? false
    }

    func box(at position: Vector) -> Rect {
        let p = position.rounded(.down)
        return Rect(x: Int(p.x) + hitbox.x, y: Int(p.y) + hitbox.y, width: hitbox.width, height: hitbox.height)
    }
}

/// An entity class that objects placed in maps are made as, named in their definition's Class. A `final` class needs
/// nothing more than this mark, since it inherits `Entity.init(_:)`, which runs its `init()` and then gives it the
/// object's sprite, hitbox and properties: `final class Villager: Entity, Placeable`. A class that isn't final makes it
/// `required` (`required convenience init(_ object: Tilemap.Object) { … }`).
@MainActor public protocol Placeable: Entity {
    /// Makes it from an object placed in a map, or made from its definition in code (`Scene.add(_:at:properties:)`).
    init(_ object: Tilemap.Object)
}

/// A picture from `<image>.png` in `Assets` or a folder in it, like `Assets/Sprites`. If `<image>.json` beside it
/// (written by the pixel editor) cuts it into frames, `play(_:)` runs one of its animations; without it, the whole
/// image is one frame.
public struct Sprite: Sendable {
    /// The image's name in Assets, without ".png".
    public var image: String
    /// The animation playing, by name; nil shows the first frame.
    public private(set) var animation: String?
    /// Mirrors the sprite horizontally, e.g. to face left.
    public var flipped = false
    /// Multiplies the sprite's pixels, as 0xRRGGBB: red (0xFF0000) for a hurt flash, or a color variant of light art.
    /// White, the default, leaves them as they are.
    public var color: UInt32 = 0xFFFFFF
    /// From 0, invisible, to 1, the default: for ghosts, or things that fade out.
    public var opacity = 1.0
    /// Mixes the sprite's pixels toward white, keeping its shape: from 0, as they are (the default), to 1, all white.
    /// Set it to 1 when something's hit, and lower it in each update for a flash that fades. On an entity's sprite,
    /// which is optional, read it first, since writing `sprite` while reading it crashes:
    /// `if let flash = sprite?.flash { sprite?.flash = max(0, flash - dt * 8) }`.
    public var flash = 0.0
    /// Adds it to what's under it, unlit, so it shines in the dark: fire, magic, sparks, a lightning bolt.
    public var glows = false
    /// How fast its animation plays: 1, the default, as its sheet says; 2 twice as fast; 0 holds it where it is.
    public var speed = 1.0
    /// One of the game's color shaders, from `Assets/Shaders`, that each of its pixels goes through: a shimmer, a pulse,
    /// a dissolve. It draws plain until the shader has compiled, and if it doesn't.
    public var shader: Shader?
    /// The way it faces in the picture, which picks the animation it plays: playing "walk" facing south-east plays
    /// "walk-se" if its `.json` has one, else "walk-sw" mirrored, else "walk". People in an isometric game face eight
    /// ways, five drawn and the three facing west mirrored. Nil, the default, plays the animation as it's named.
    public var facing: Direction?
    var time = 0.0

    /// A sprite of one of the game's images: `Sprite(.slime)`.
    public init(_ image: ImageName) { self.image = image.name }

    /// A sprite of an image named in a string, like one that comes from data.
    @_disfavoredOverload public init(_ image: String) { self.image = image }

    /// Starts the named animation. Playing the one that's already running keeps it going, so it's fine every frame.
    public mutating func play(_ animation: String) {
        if animation != self.animation { (self.animation, time) = (animation, 0) }
    }

    /// Starts the named animation, from its first frame if `restart`, even when it's the one playing: a second swing
    /// the same as the first.
    public mutating func play(_ animation: String, restart: Bool) {
        if restart || animation != self.animation { (self.animation, time) = (animation, 0) }
    }

    /// Which of its animation's frames shows, counting from 0 as its sheet lists them; 0 with none. Set it to go to one
    /// and play on from there: a swing started from its wind-up's last frame.
    public var frame: Int {
        get { animation.flatMap { sheetAnimation($0, of: image) }.map { $0.step(at: time) } ?? 0 }
        set {
            guard let playing = animation.flatMap({ sheetAnimation($0, of: image) }), playing.fps > 0 else { return }
            time = (Double(newValue) + 0.001) / playing.fps // a thousandth in, so it's that frame and not the end of the one before
        }
    }

    /// Whether its animation is one that doesn't loop (its sheet's `loop: false`) and has shown its last frame for that
    /// frame's time: a swing's over. One that loops is never finished.
    public var finished: Bool {
        guard let playing = animation.flatMap({ sheetAnimation($0, of: image) }), playing.loop == false else { return false }
        return time * playing.fps >= Double(playing.frames.count)
    }

    /// Faces the way `way` goes across the picture, the nearest of eight; for none, it faces as it did. An entity
    /// walking on an isometric floor faces the way its velocity goes there: `face(scene.projection.picture(of: velocity))`.
    public mutating func face(_ way: Vector) {
        if way != .zero { facing = Direction(way) }
    }
}

/// Object definitions and maps, read `once`.
let definitionsRead = Mutex<[String: ObjectFile?]>([:])
let mapsLoaded = Mutex<[String: Tilemap]>([:])

/// A grid of tiles from a tileset, `<tileset>.png` in `Assets` or a folder in it, cut into `tileSize` squares numbered
/// left to right, then top to bottom.
///
/// While the game runs from the editor or with `swift run`, the current scene's tilemap reloads when its `.tilemap`
/// (or the tileset's `.json`, or one of its objects' definitions) changes, so tiles painted in the editor show up live;
/// in an app, whose files can't change, it doesn't. Entities already in the scene stay as they are: objects moved or
/// added in the editor show up the next time the game builds the level.
public struct Tilemap: Sendable {
    /// The tileset image's name in Assets, without ".png".
    public var tileset: String
    /// The width and height of a tile, in pixels.
    public var tileSize: Int
    /// Size in tiles.
    public var width, height: Int
    /// Each layer's tiles row by row, `layers[layer][row * width + column]`; nil is empty. The first layer draws first.
    public var layers: [[Int?]]
    /// The layers that draw over the entities, like roofs and treetops, by their index in `layers`.
    public var above: Set<Int> = []
    /// Tile numbers that block movement, in any layer.
    public var solid: Set<Int>
    /// Tile numbers that stop the light of a `Light` with shadows, in any layer: walls, trunks, rock.
    public var opaque: Set<Int> = []
    /// What the tileset says of its tiles, for `properties(at:layer:)`.
    var sheet: SheetFile?
    /// Things placed in the level with the map editor's Objects tool, like coins or where the player starts.
    public var objects: [Object] = []
    /// How it's drawn, from its file: flat, as it lies, or isometric, its cells diamonds twice as wide as tall, its tiles
    /// the floor, drawn before what stands on it, and its entities standing on their hitboxes, their footprints. Set it
    /// on a map made from text.
    public var projection: Projection = .flat
    /// The lights its tiles give by their tileset's properties, each at its tile's middle: `light`, how far it reaches in
    /// pixels, which lights it, and `lightColor`, `lightFlicker`, `lightBrightness` and `lightShadows`, as a `Light`'s,
    /// set in the map editor's tile panel. A torch painted on a wall lights it. The scene lights them as its `lamps`.
    public internal(set) var lamps: [Lamp] = []
    var names: [String] = [] // each layer's, as the map editor named it
    var name: String? // the .tilemap it came from
    var watched: [String] = [] // it, the tileset's .json and its objects' definitions
    var modified: [Date?] = [] // when each was last changed, as loaded
    var removed: Set<Int> = [] // what removeTiles took out, kept out when the map reloads
    var edits: [SIMD3<Int>: Int?] = [:] // what setTile put down, by layer, column and row, kept when the map reloads
    var time = 0.0 // for animated tiles, advanced by the scene's updates

    /// Something placed in the level with the map editor's Objects tool. What it is comes from its definition,
    /// `Assets/Objects/<name>.object`, if it has one: its sprites, its hitbox, whether it's solid or opaque, its class,
    /// and its properties' defaults.
    public struct Object: Properties, Sendable {
        /// What it is, like "coin" or "player", and its definition's file name; `objects(named:)` finds them by it.
        public var name: String
        /// Top-left corner, in pixels.
        public var position: Vector
        /// Settings for the game, like "speed": "40": its own, over its definition's defaults. `double(_:)`, `map(_:)`
        /// and the others read them as what they are.
        public var properties: [String: String]
        /// What it's drawn with, playing its definition's animation; nil for a zone, a marker, or an object without a
        /// definition.
        public var sprite: Sprite?
        /// The other sprites its definition draws it with.
        public var parts: [Entity.Part]
        /// The part that collides, from its top-left corner: its definition's, or all of it.
        public var hitbox: Rect
        /// Blocks other entities as they move, as `Entity.solid` does.
        public var solid: Bool
        /// Its hitbox stops the light of a `Light` with shadows, as `Entity.opaque` does.
        public var opaque: Bool
        /// The game's class it's made as by `Scene.addObjects()`, by name.
        public var `class`: String?
        var size: Size

        /// Where it is and how big, in pixels: the size it was given in the map editor, or else a zone's size or its
        /// sprite's frame, or without a definition the frame of the image it's named after, or one tile. For zones
        /// like doors: `player.overlaps(door.box)`.
        public var box: Rect { Rect(x: Int(position.x), y: Int(position.y), width: size.width, height: size.height) }

        init(_ placed: TilemapFile.Object, definition: ObjectFile?, tileSize: Int, projection: Projection = .flat, frame: (String) -> Size?) {
            // In an isometric map, a sprite stands on its object's footprint, so its frame isn't the object's size.
            let size = placed.size(definition, tileSize: tileSize) { projection == .isometric ? nil : frame($0).map { ($0.width, $0.height) } }
            (name, position, properties) = (placed.name, [Double(placed.x), Double(placed.y)], placed.properties(definition))
            func playing(_ image: String, _ animation: String?) -> Sprite {
                var sprite = Sprite(image)
                if let animation { sprite.play(animation) }
                return sprite
            }
            sprite = definition?.sprite.map { playing($0, definition?.animation) }
            parts = (definition?.parts ?? []).map { .init(playing($0.sprite, $0.animation), offset: [Double($0.x), Double($0.y)], above: $0.above == true) }
            hitbox = definition?.hitbox.map { Rect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
                ?? Rect(x: 0, y: 0, width: size.width, height: size.height)
            (solid, opaque, `class`, self.size) = (definition?.solid ?? false, definition?.opaque ?? false, definition?.class, Size(size.width, size.height))
        }
    }

    /// Loads `<name>.tilemap` from `Assets` or a folder in it, like `Assets/Maps`, made in the tilemap editor. The tile
    /// size and which tiles are solid and opaque come from the tileset's `.json`, and what its objects are from their
    /// definitions.
    public init(_ map: MapName) { self.init(map.name) }

    /// Loads a map named in a string, like a door's `to`. One that's missing or can't be read is empty, and the console
    /// says why, once, so the game goes on; where files can change, it loads once its file is there.
    @_disfavoredOverload public init(_ name: String) {
        // `once`: in an app, going back to a map, like the island from a house, reads nothing again (25 to 39 ms on an
        // iPhone for Driftwood's island).
        do {
            self = try once(name, in: mapsLoaded) {
                var map = Tilemap()
                try map.load(name)
                return map
            }
        } catch {
            say(once: "\(name).tilemap", "Spellcrest: can't load \(assetURL("\(name).tilemap").path), so it's empty: \(error.localizedDescription)")
            self = Tilemap()
            self.name = name
            watched = ["\(name).tilemap"]
            modified = [modificationDate(assetURL("\(name).tilemap"))]
        }
    }

    /// An empty map, for `load` to fill. Its tiles are a size, so working out a cell never divides by nothing.
    private init() { (tileset, tileSize, width, height, layers, solid) = ("", 16, 0, 0, [], []) }

    mutating func load(_ name: String) throws {
        let map = try TilemapFile(contentsOf: assetURL("\(name).tilemap"))
        let sheet = try SheetFile(contentsOf: assetURL("\(map.tileset).json"))
        projection = map.projection == .isometric ? .isometric : .flat
        let cell = projection == .isometric ? max(sheet.frameWidth / 2, 1) : sheet.frameWidth // a diamond is twice as wide as its cell
        (tileset, tileSize, width, height) = (map.tileset, cell, map.width, map.height)
        layers = map.layers.map { $0.tiles.map { $0 < 0 ? nil : $0 } }
        names = map.layers.map(\.name)
        above = Set(map.layers.indices.filter { map.layers[$0].above == true })
        (solid, opaque) = (Set(sheet.solid ?? []), Set(sheet.opaque ?? []))
        self.sheet = sheet
        let names = Set((map.objects ?? []).map(\.name)).sorted()
        var definitions: [String: ObjectFile] = [:]
        for name in names {
            let url = assetURL("\(name).object")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { definitions[name] = try ObjectFile(contentsOf: url) } catch { print("Spellcrest: can't read \(url.path): \(error.localizedDescription)") }
        }
        var frames: [String: Size?] = [:] // each image's frame size, read once
        objects = (map.objects ?? []).map { placed in
            Object(placed, definition: definitions[placed.name], tileSize: tileSize, projection: projection) { image in
                if frames[image] == nil { frames[image] = .some(frameSize(image)) }
                return frames[image]!
            }
        }
        // Watched for changes: the map, its tileset's .json and its objects' definitions.
        self.name = name
        watched = ["\(name).tilemap", "\(map.tileset).json"] + names.map { "\($0).object" }
        modified = watched.map { modificationDate(assetURL($0)) }
        for tile in removed { _ = removeTiles(tile) }
        for (cell, tile) in edits where layers.indices.contains(cell.x) && (0..<width).contains(cell.y) && (0..<height).contains(cell.z) {
            layers[cell.x][cell.z * width + cell.y] = tile
        }
        findLamps()
    }

    /// Loads the map again if its files changed. One that can't be read keeps the map as it is.
    mutating func reloadIfChanged() {
        guard let name else { return }
        let dates = watched.map { modificationDate(assetURL($0)) }
        guard dates != modified else { return }
        modified = dates // so a broken file is tried again only once it changes again
        try? load(name)
    }

    /// Builds a one-layer map from text, one string per row. `legend` maps characters to tile numbers;
    /// any other character is empty. Every tile in the legend is solid unless you pass `solid`. The tileset's `.json`,
    /// if it has one, gives its tiles' properties and which are opaque, as it does a map's from a file.
    public init(_ tileset: ImageName, tileSize: Int, rows: [String], legend: [Character: Int], solid: Set<Int>? = nil) {
        self.init(tileset.name, tileSize: tileSize, rows: rows, legend: legend, solid: solid)
    }

    /// The same, with the tileset named in a string.
    @_disfavoredOverload public init(_ tileset: String, tileSize: Int, rows: [String], legend: [Character: Int], solid: Set<Int>? = nil) {
        let width = rows.map(\.count).max() ?? 0
        (self.tileset, self.tileSize, self.width, height) = (tileset, tileSize, width, rows.count)
        layers = [rows.flatMap { row in row.map { legend[$0] } + Array(repeating: nil, count: width - row.count) }]
        self.solid = solid ?? Set(legend.values)
        let url = assetURL("\(tileset).json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { sheet = try SheetFile(contentsOf: url) } catch { print("Spellcrest: can't read \(url.path): \(error.localizedDescription)") }
        }
        opaque = Set(sheet?.opaque ?? [])
        findLamps()
    }

    /// Size in pixels: on the floor, for an isometric map.
    public var size: Size { Size(width * tileSize, height * tileSize) }

    /// The part of its scene's picture it covers: its size for a flat map; for an isometric one its diamond's box, from
    /// its last row's left corner to its last column's right one, and from its first cell's top to its last's bottom.
    var picture: Rect {
        guard projection == .isometric else { return Rect(x: 0, y: 0, width: size.width, height: size.height) }
        return Rect(x: -height * tileSize, y: 0, width: (width + height) * tileSize, height: (width + height) * tileSize / 2)
    }

    /// The number of the layer the map editor named `name`, for `tile(at:layer:)` and the rest: so a game finds its
    /// paths' layer however many are added under it. Nil when there's none, as in a map made in code.
    public func layer(named name: String) -> Int? { names.firstIndex(of: name) }

    /// The tile at world pixel `point` in `layer`, or nil for an empty cell or outside the map: what's under the
    /// player's feet, or in front of them.
    public func tile(at point: Vector, layer: Int) -> Int? {
        guard let i = index(point), layers.indices.contains(layer) else { return nil }
        return layers[layer][i]
    }

    /// The properties of the tile at world pixel `point` in `layer`, which the map editor sets for each of the
    /// tileset's tiles: water, ice, damage, a footstep's sound. `bool(_:)`, `double(_:)` and the others read them, as an
    /// object's: `tilemap.properties(at: feet, layer: 0).bool("water")`. An empty cell, or outside the map, has none.
    public func properties(at point: Vector, layer: Int) -> TileProperties {
        TileProperties(properties: tile(at: point, layer: layer).flatMap { sheet?.properties(of: $0) } ?? [:])
    }

    /// A tile's properties, from `properties(at:layer:)`.
    public struct TileProperties: Properties, Sendable {
        /// The tile's values over its tileset's defaults, by name, as text; `bool(_:)` and the others read them.
        public let properties: [String: String]
    }

    /// Puts `tile` at world pixel `point` in `layer`, or empties the cell with nil: cut a bush, till soil, build a
    /// wall. Outside the map it does nothing. The change stays when the map reloads as it's edited in the editor.
    public mutating func setTile(_ tile: Int?, at point: Vector, layer: Int) {
        guard let i = index(point), layers.indices.contains(layer) else { return }
        let old = layers[layer][i]
        layers[layer][i] = tile
        edits.updateValue(tile, forKey: [layer, i % width, i / width]) // not `edits[…] = tile`, which removes it when nil
        if old.flatMap(light(of:)) != nil || tile.flatMap(light(of:)) != nil { findLamps() } // a torch put up or taken down
    }

    /// The cell world pixel `point` is in, as an index into a layer; nil outside the map.
    private func index(_ point: Vector) -> Int? {
        let (column, row) = (cell(Int(point.x.rounded(.down))), cell(Int(point.y.rounded(.down))))
        return (0..<width).contains(column) && (0..<height).contains(row) ? row * width + column : nil
    }

    /// The frame each animated tile shows now: an animation in the tileset's `.json` named after a tile's number
    /// ("12") plays wherever that tile is, for water, flowers and torches.
    func frames(_ animations: [String: SheetFile.Animation]?) -> [Int: Int] {
        (animations ?? [:]).reduce(into: [:]) { frames, animation in
            if let tile = Int(animation.key), let frame = animation.value.frame(at: time) { frames[tile] = frame }
        }
    }

    /// Where each object called `name` is (its top-left corner, in pixels).
    public func objects(named name: ObjectName) -> [Vector] { objects(named: name.name) }

    /// The same, with the object named in a string, like a door's `at`.
    @_disfavoredOverload public func objects(named name: String) -> [Vector] { objects.filter { $0.name == name }.map(\.position) }

    /// Removes every `tile` from the map and returns where each one was (top-left corner, in pixels).
    /// Handy for tiles that only mark where things go, like coins or the player's start.
    public mutating func removeTiles(_ tile: Int) -> [Vector] {
        removed.insert(tile)
        var found: [Vector] = []
        for layer in layers.indices {
            for i in layers[layer].indices where layers[layer][i] == tile {
                layers[layer][i] = nil
                found.append([Double(i % width * tileSize), Double(i / width * tileSize)])
            }
        }
        if !found.isEmpty, light(of: tile) != nil { findLamps() }
        return found
    }

    /// Whether a solid tile in any layer overlaps `box`. Outside the map is empty.
    func isSolid(_ box: Rect) -> Bool {
        for row in stride(from: cell(box.y), through: cell(box.y + box.height - 1), by: 1) where (0..<height).contains(row) {
            for column in stride(from: cell(box.x), through: cell(box.x + box.width - 1), by: 1) where (0..<width).contains(column) {
                if layers.contains(where: { $0[row * width + column].map(solid.contains) ?? false }) { return true }
            }
        }
        return false
    }

    /// Which cell a pixel is in, rounding toward -∞ so pixels left of or above the map get negative cells.
    func cell(_ pixel: Int) -> Int { pixel >= 0 ? pixel / tileSize : (pixel + 1) / tileSize - 1 }

    /// The cell, its column and row, that world pixel `point` is in.
    func cell(at point: Vector) -> SIMD2<Int> { [cell(Int(point.x.rounded(.down))), cell(Int(point.y.rounded(.down)))] }

    /// The shortest way from cell `start` to cell `goal` through the map's cells that are `free`, by A*: the cells
    /// after `start` to `goal`, or nil when there's none, or `goal` isn't free or is off the map. Steps go to a cell
    /// beside, above or below, or with `diagonals` to one at a corner when both cells beside that corner are free too.
    /// Of the shortest ways, it takes one that turns the fewest times, as someone walking would.
    // ponytail: arrays of the map's size times its steps for each search; a dictionary of the states it looks at if
    // maps get so big that filling them is slow.
    func route(from start: SIMD2<Int>, to goal: SIMD2<Int>, diagonals: Bool, free: (SIMD2<Int>) -> Bool) -> [SIMD2<Int>]? {
        func inside(_ x: Int, _ y: Int) -> Bool { (0..<width).contains(x) && (0..<height).contains(y) }
        guard inside(start.x, start.y), inside(goal.x, goal.y), free(goal) else { return nil }
        var known = [UInt8](repeating: 0, count: width * height) // each cell's `free`, asked once: 1 free, 2 not
        func open(_ x: Int, _ y: Int) -> Bool {
            guard inside(x, y) else { return false }
            if known[y * width + x] == 0 { known[y * width + x] = free([x, y]) ? 1 : 2 }
            return known[y * width + x] == 1
        }
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)] + (diagonals ? [(1, 1), (-1, 1), (-1, -1), (1, -1)] : [])
        // A state is a cell and the step into it (the start's is none, `steps.count`), so a turn can cost something: 1,
        // where a step costs 10,000 across and 14,000 diagonally, so turns only choose among the shortest ways.
        let ways = steps.count + 1
        func estimate(_ x: Int, _ y: Int) -> Int {
            let (x, y) = (abs(x - goal.x), abs(y - goal.y))
            return (diagonals ? 10 * max(x, y) + 4 * min(x, y) : 10 * (x + y)) * 1000
        }
        var cost = [Int](repeating: .max, count: width * height * ways), came = [Int](repeating: -1, count: width * height * ways)
        // The least each cell costs to reach, from any side. A state that costs more is left out: going on from the
        // cheapest instead costs at most a turn more, and that's no more.
        var least = [Int](repeating: .max, count: width * height)
        let first = (start.y * width + start.x) * ways + steps.count
        (cost[first], least[start.y * width + start.x]) = (0, 0)
        // A binary heap of states to go on from: the one whose way through it, as estimated, is shortest, then the one
        // nearer the goal, then the one added last (`rest`: the estimate in the high bits, less the count added before).
        var heap = [(f: estimate(start.x, start.y), rest: estimate(start.x, start.y) << 32, state: first)]
        func before(_ a: Int, _ b: Int) -> Bool { heap[a].f < heap[b].f || heap[a].f == heap[b].f && heap[a].rest < heap[b].rest }
        var added = 0, found: Int?
        while !heap.isEmpty {
            heap.swapAt(0, heap.count - 1)
            let (f, _, state) = heap.removeLast()
            var i = 0
            while true { // sift down
                var next = i
                if 2 * i + 1 < heap.count, before(2 * i + 1, next) { next = 2 * i + 1 }
                if 2 * i + 2 < heap.count, before(2 * i + 2, next) { next = 2 * i + 2 }
                if next == i { break }
                heap.swapAt(i, next)
                i = next
            }
            let (x, y) = (state / ways % width, state / ways / width)
            guard f - estimate(x, y) == cost[state], cost[state] <= least[y * width + x] else { continue } // bettered since
            if x == goal.x, y == goal.y {
                found = state
                break
            }
            for way in steps.indices {
                let (dx, dy) = steps[way], (nx, ny) = (x + dx, y + dy)
                guard open(nx, ny), dx == 0 || dy == 0 || open(nx, y) && open(x, ny) else { continue } // no corner cut
                let turn = state % ways == way || state % ways == steps.count ? 0 : 1
                let total = cost[state] + (dx != 0 && dy != 0 ? 14_000 : 10_000) + turn
                let after = (ny * width + nx) * ways + way
                guard total < cost[after], total <= least[ny * width + nx] else { continue }
                (cost[after], came[after], least[ny * width + nx]) = (total, state, total)
                added += 1
                heap.append((total + estimate(nx, ny), estimate(nx, ny) << 32 - added, after))
                var j = heap.count - 1
                while j > 0, before(j, (j - 1) / 2) { // sift up
                    heap.swapAt(j, (j - 1) / 2)
                    j = (j - 1) / 2
                }
            }
        }
        guard var state = found else { return nil }
        var cells: [SIMD2<Int>] = []
        while came[state] >= 0 {
            cells.append([state / ways % width, state / ways / width])
            state = came[state]
        }
        return cells.reversed()
    }
}

/// What has properties from the editor, typed there and kept as text: a map's objects, and its tiles
/// (`Tilemap.properties(at:layer:)`). These read them as what they are, so `door.map("to")` is a `MapName` that
/// `Tilemap(_:)` takes. Each is nil (false for `bool`, empty for `list`) when there's none, when it isn't of its type,
/// or when it's empty, as a popup's None over a default is.
public protocol Properties {
    /// Every property by name, as the text it's kept as, "40" or "#FF004D": what the readers below read.
    var properties: [String: String] { get }
}

public extension Properties {
    /// A number, like "speed": "40".
    func double(_ name: String) -> Double? { value(name) }

    /// A whole number, like "hits": "3"; nil for one with a fraction, like "2.5".
    func int(_ name: String) -> Int? { value(name) }

    /// Text, as it was typed, like "tier": "stone".
    func text(_ name: String) -> String? { properties[name].flatMap { $0.isEmpty ? nil : $0 } }

    /// A toggle, "true" or "false"; false if there's none.
    func bool(_ name: String) -> Bool { properties[name] == "true" }

    /// A color, "#FF004D", as 0xRRGGBB, like `Sprite.color` takes.
    func color(_ name: String) -> UInt32? { properties[name]?.hasPrefix("#") == true ? value(name) : nil }

    /// A point in world pixels, "12,34", like where a guard walks to.
    func point(_ name: String) -> Vector? { value(name) }

    /// One of the game's maps, by name: `Tilemap(door.map("to")!)`.
    func map(_ name: String) -> MapName? { value(name) }

    /// One of the game's objects, by name: `tilemap.objects(named: door.object("at") ?? .start)`.
    func object(_ name: String) -> ObjectName? { value(name) }

    /// One of the game's images, by name: `Sprite(chest.sprite("open")!)`.
    func sprite(_ name: String) -> ImageName? { value(name) }

    /// One of the game's sounds, by name: `Sound.play(step.sound("footstep")!)`.
    func sound(_ name: String) -> SoundName? { value(name) }

    /// A list, its values read as `Value`s, leaving out any that aren't one: `villager.list("words", of: String.self)`,
    /// `guard.list("path", of: Vector.self)`.
    func list<Value: PropertyValue>(_ name: String, of type: Value.Type = Value.self) -> [Value] {
        (properties[name] ?? "").split(separator: "\n").compactMap { Value(property: String($0)) }
    }

    private func value<Value: PropertyValue>(_ name: String) -> Value? { properties[name].flatMap(Value.init(property:)) }
}

/// What a property's text can be read as, for `Properties.list(_:of:)`: text, numbers, toggles, colors, points and the
/// game's asset names.
public protocol PropertyValue {
    /// The value a property's text is, or nil when it isn't one: "40" is a `Double`, "chest" isn't.
    init?(property text: String)
}

/// Text, as it is.
extension String: PropertyValue {
    /// The text itself.
    public init?(property text: String) { self = text }
}

/// A number, "40" or "2.5".
extension Double: PropertyValue {
    /// The number the text is; nil for anything else.
    public init?(property text: String) { self.init(text) }
}

/// A whole number, "3".
extension Int: PropertyValue {
    /// The whole number the text is, "3" or "3.0"; nil for one with a fraction, like "2.5", or anything else.
    public init?(property text: String) {
        guard let number = Double(text).flatMap({ Int(exactly: $0) }) else { return nil }
        self = number
    }
}

/// A toggle, "true" or "false".
extension Bool: PropertyValue {
    /// True for "true", false for "false", and nil for anything else.
    public init?(property text: String) { self.init(text) }
}

/// A color, as 0xRRGGBB.
extension UInt32: PropertyValue {
    /// A color, "#FF004D", or a whole number.
    public init?(property text: String) {
        if text.hasPrefix("#") { self.init(text.dropFirst(), radix: 16) } else { self.init(text) }
    }
}

/// A point, a `Vector`.
extension SIMD2: PropertyValue where Scalar == Double {
    /// A point, "12,34".
    public init?(property text: String) {
        let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 2 else { return nil }
        self.init(numbers[0], numbers[1])
    }
}

extension ImageName: PropertyValue {
    /// The image the text names; nil when it's empty.
    public init?(property text: String) { if text.isEmpty { return nil } else { self.init(text) } }
}

extension MapName: PropertyValue {
    /// The map the text names; nil when it's empty.
    public init?(property text: String) { if text.isEmpty { return nil } else { self.init(text) } }
}

extension ObjectName: PropertyValue {
    /// The object the text names; nil when it's empty.
    public init?(property text: String) { if text.isEmpty { return nil } else { self.init(text) } }
}

extension SoundName: PropertyValue {
    /// The sound the text names; nil when it's empty.
    public init?(property text: String) { if text.isEmpty { return nil } else { self.init(text) } }
}
