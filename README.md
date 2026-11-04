# Spellcrest

A Swift engine for 2D pixel art games on the Mac, iPhone and iPad.

Games are Swift packages that depend on Spellcrest. They run on macOS 15 or later and iOS 18 or later, and building them needs Xcode or the Swift toolchain (developed with Swift 6.4).

## Five-minute start

In an empty folder, make `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hello",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [.package(url: "https://github.com/oddis98/Spellcrest.git", from: "0.17.0")],
    targets: [.executableTarget(name: "Hello", dependencies: [.product(name: "Spellcrest", package: "Spellcrest")])]
)
```

and `Sources/Hello/Hello.swift`:

```swift
import Spellcrest

@main struct Hello: Game {
    func start() -> Scene { Title() }
}

final class Title: Scene {
    override func update(_ dt: Double) {
        super.update(dt)
        if Input.pressed(.a) { background = .random(in: 0...0xFFFFFF) } // Space or Z
    }
}
```

Then `swift run`. A window opens on a 320×180 canvas; press Space for a new color.

## How a game works

- **A game** is the `@main` type that conforms to `Game`. It gives the size of its canvas (`resolution`, 320×180 unless it says otherwise), which the window scales up by whole numbers so pixels stay square, and the `Scene` it starts in. On an iPhone or iPad it can give a canvas for the screen as it's held (`resolution(for:)`, from its `Display`), asked again as it turns or a foldable opens, each scene then laying itself out again (`Scene.resized(from:)`) from `Input.canvas`.
- **A scene** updates 60 times a second (`update(_:)`) and draws its tilemap, its entities and whatever else it draws on the `Screen` (`draw(_:)`), through a `camera` that can `follow` an entity. `Scene.transition(to:style:)` goes to the next scene with a fade, a wipe, an iris or a dissolve.
- **Entities** are what moves: a position, a velocity, a hitbox and a `Sprite`. `move(dt)` moves one by its velocity, stopping it flush against solid tiles and other solid entities, and `path(to:)` finds a way around walls that `walk(_:along:speed:)` follows.
- **Sprites** are PNGs, cut into frames and animations by a `.json` beside them: `Sprite("player")`, then `sprite.play("walk")`. They tint, fade, and `flash` white when hit.
- **Tilemaps** are levels: layers of tiles from a tileset, some drawn above the entities (roofs, treetops), with solid tiles, properties on tiles, and objects placed on them. A scene's `addObjects()` makes each object as its Swift class (`final class Coin: Entity, Placeable`), which reads the object's properties as what they are: `door.map("to")`, `chest.int("coins")`. `add(.chest, at: point)` makes one in code from its definition, for what the player builds or what comes out at night, and `make(.chest, at: point)` makes one without adding it. A map's layers go by the names the map editor gives them: `tilemap.layer(named: "Paths")`.
- **An isometric camera:** a map whose `projection` is `.isometric` is seen from above at an angle, as Witchbrook's are: its cells are diamonds twice as wide as tall, and each entity stands on its hitbox, its footprint on the floor, drawn in front of and behind the others as boxes standing apart there are. The walls of the room the followed entity is in are drawn cut down to a sill (an object's `room` and `cut`), its light lies on the floor and lights what stands from the floor under it, `Input.direction(in: scene)` walks the floor's lines, and a sprite's `facing` plays `walk-se`, mirrored for the ways not drawn.
- **Assets** live in the game's `Assets` folder, in `Sprites`, `Tilesets`, `Maps`, `Objects`, `Sounds` and `Shaders`, and are found by name. For names the compiler checks, extend `ImageName`, `MapName`, `SoundName`, `ObjectName` and `ShaderName` (`static let player = ImageName("player")`) and write `Sprite(.player)`. A file of the game's own, like a level's data, is found the same way, in an app too: `Assets.url("words.txt")`. One that's missing draws or plays nothing, and the console says which.
- **Input** is one gamepad, the D-pad, A, B, X, Y and Start, from the keyboard, game controllers, and on iPhone and iPad touch controls drawn over the game: `Input.pressed(.a)`, and `Input.released(.a)` as it's let go. `Input.direction` is where the player's pushing, the stick or the D-pad, no longer than 1, and `Input.using` whether that's a keyboard, a controller or touch, for hints that name a button. A keyboard has keys of its own too: `Input.pressed(key: .escape)`. The mouse or a finger is the pointer: `Input.pointer` is where it is, in canvas pixels, and `Input.pressed(.pointer)` a click or a tap.
- **Sound and music:** `Sound.play(.jump)` for effects, at a `pitch` and a `pan` if you like, and `Sound.stop(.fire)` to stop one early; and `Music.play(.theme, fade: 1)`, which loops and pauses with the game, `Music.pause()` for a pause menu, and `Music.stop(fade: 1)`. `Sound.volume` and `Music.volume` turn each down, for a game's settings.
- **Text:** `screen.text` writes with a built-in 3×5 font or one drawn as an image, scaled by whole numbers, faded and aligned, and `screen.panel` draws text boxes that stretch. `screen.textSize` and `screen.size(of: .title)` measure text and images to lay them out, and `screen.draw(.title, x: 40, y: 20, scale: 3)` draws an image bigger.
- **Light:** a scene's `darkness` dims the world toward a color, and lights light it again: the `Light`s its entities carry, a fire, a lantern; its `lamps`, where there's no entity; and its map's tiles that light by their tileset's properties, like a torch painted on a wall in the map editor. A light with `shadows` stops at the tiles a tileset marks opaque and at opaque entities' hitboxes (`opaque`), so trunks and walls cast shadows; one brighter than 1 lights past daylight, like a flash of lightning by day, and one below 0 takes light away, like a gloom, its `gray` draining color too. An `image` shapes a light, turned by its `angle`. The light is worked out at the game's pixels before the world is drawn, each pixel lit as a whole, as its art is, so it's sharp and costs the same at any size; what's drawn after `super.draw`, like a HUD, stays lit.
- **Weather and mood:** `clouds` drift over a scene, shading its daylight; `fog` drifts over its world, lit as the ground is; both are soft unless they're `smooth: false`, when their edges are dithered as pixel art's are; `weather` makes it rain, its streaks catching the light, or snow; `vignette` darkens the view's corners, and `gray` drains the world's color. `backdrops` (a sky, far hills) and `overhangs` (a canopy of leaves) are images behind the map and over the world that move at their own rate as the camera does, repeat and sway. `shake(_:)` shakes the view (`shakeOffset` says how far, for what's placed by the camera), and `screen.bolt` draws a lightning bolt; a sprite that `glows` is added to what's under it, so it shines in the dark.
- **Particles:** an `Emitter` says how they come out, move and look: sparks, embers, smoke and motes, squares of pixels or an image's frames, glowing in the dark or lit as the ground is. An entity's `emitter` gives them off as it goes, and `scene.particles.burst(sparks, at: point, count: 30)` throws out a burst anywhere. In a `ySort` scene they draw among the entities by where they came out, so a spark from behind a tree stays behind it.
- **Glow and air that bends:** a scene's `bloom` spreads what glows, sprites, particles and lightning bolts, and light past daylight, softly into the dark around it; its `bends` move the picture round points in the world, a ring going out where a spell lands, heat haze over a fire, a swirl, each drawn only where it is.
- **Light that shapes the art:** a scene's `shaping` shows which side its lights are on. An image with a normal map beside it, `tree.normal.png`, is lit by it, brighter where it faces a light and darker where it faces away, and with `.rim` a sprite without one catches a rim of light on its edges facing it. Only lights shape, not daylight, so a scene by day looks as it did.
- **Shaders:** a game can write its own in Metal, `Assets/Shaders/<name>.metal`, a function named as its file, as SwiftUI's are. A color shader, `half4 name(float2 position, half4 color, Values values)`, goes on a sprite (`sprite.shader = Shader(.shimmer, [0.5])`); a layer shader, `half4 name(float2 position, Layer layer, Values values)`, goes on the picture (`scene.effects = [Shader(.ripple, [x, y, t])]`) and reads it with `layer.sample(position)`. They compile while the game runs, again when their file is saved, and print their errors with the file and line. A layer shader runs for every pixel of the canvas at the screen's scale, so one that changes part of the picture returns early everywhere else.
- **Saves:** `Save.write(progress, to: "progress")` and `Save.read(Progress.self, from: "progress")` keep `Codable` values between launches, the engine's own among them: a `Vector`, a `Size`, a `Rect` and the asset names.
- **Steam:** a game sold on Steam for the Mac adds the `SpellcrestSteam` product beside `Spellcrest` (`.product(name: "SpellcrestSteam", package: "Spellcrest")`) and calls `Steam.start(appID:)` first thing in its `start()`, before its window is made, so Steam's overlay can draw over it; then `Steam.achieve("first-bell")`, `Steam.stat("bells", 3)` and `Steam.name`. It goes through Steam's own library, `libsteam_api.dylib` from the Steamworks SDK, which the editor's Export for Steam puts in the app; while you make the game, the editor's Run finds it in the SDK its Settings name, or `swift run` in the SDK that `STEAMWORKS_SDK` names, and Steam is told the app ID. Without it, or without Steam running, the game plays as it would anywhere, and the console says why. Saves reach Steam Cloud with no code: on the game's Steamworks page, Auto-Cloud's root `MacAppSupport`, its folder the game's executable's name, its files `*.json`.

## Examples

- [`Examples/Platformer`](Examples/Platformer): a level to run and jump through, with coins, animations, collisions and sounds.
- [`Examples/Village`](Examples/Village): a top-down game. Walk behind trees and under roofs as clouds drift over, through a door into a house lit by its fire and the torches on its walls, and through a gap in the hedge into a wood at dusk, in the rain under a canopy of leaves, lit by your lantern, the trees round in its light; talk to a villager who walks around a hedge to the garden; call lightning down with Y (V on a keyboard), its flash blooming and its sparks flying, and a gloom with B (X), the air turning in it and full of motes; the air shimmers over the house's fire. It saves where you are.

- [`Examples/Isometric`](Examples/Isometric): a hall at night seen from above at an angle, as Witchbrook's rooms are: its floor in diamonds, its walls, table and fire standing on it, in front of and behind each other as they stand. Walk in with the D-pad, or a click or a tap, and its two near walls drop to sills; the fire lights its floor, and the walls' feet more than their tops, and the villager walks round it in eight directions.

Run one with `cd Examples/Platformer && swift run`.

## Versions

Before 1.0, a minor version (0.2, 0.3, …) may change the API.

Spellcrest was called PixelKit before 0.17.0. A game made with PixelKit moves to it by importing `Spellcrest` instead, and by naming `https://github.com/oddis98/Spellcrest.git` and the product `Spellcrest` in its `Package.swift`; Spellcrest's editor offers to do this as it opens one.

Spellcrest is released under the [MIT License](LICENSE).
