import Metal
import Testing
@testable import Spellcrest

@MainActor @Test func aSpriteFlashesWhiteKeepingItsShape() throws {
    let screen = try canvas(Size(3, 1))
    screen.textures["dot"] = try texture([0xFF00_00FF, 0, 0xFF00_FF00], width: 3) // red, clear, green
    screen.sheets["dot"] = .some(nil)
    var sprite = Sprite("dot")
    sprite.flash = 1
    #expect(try render(screen) { screen.draw(sprite, x: 0, y: 0) } == [0xFFFF_FFFF, 0xFF00_0000, 0xFFFF_FFFF]) // the clear pixel stays clear
    sprite.flash = 0.5
    let red = try render(screen) { screen.draw(sprite, x: 0, y: 0) }[0]
    #expect(red >> 16 & 0xFF == 0xFF && (0x7F...0x80).contains(red >> 8 & 0xFF) && (0x7F...0x80).contains(red & 0xFF)) // halfway to white
}

@MainActor @Test func transitionsCoverTheViewSwitchAndUncoverWhileTheOldSceneStandsStill() {
    final class Counted: Scene {
        var updates = 0
        override func update(_ dt: Double) { updates += 1 }
    }
    let (village, house) = (Counted(), Counted())
    Scene.current = village
    defer { (Scene.current, Scene.changing) = (Scene(), nil) }
    Scene.fade(to: house, duration: 1, color: 0x102030)
    var covers: [Double] = []
    for _ in 0..<8 {
        Scene.tick(0.125)
        covers.append(Scene.changing?.cover ?? 0)
    }
    #expect(covers == [0.25, 0.5, 0.75, 1, 0.75, 0.5, 0.25, 0])
    #expect(village.updates == 0 && house.updates == 5 && Scene.current === house && Scene.changing == nil) // from the switch on

    // A wipe covers from its side until the switch, then uncovers toward the other.
    var wipe = Change(duration: 1, style: .wipe(from: .left), color: 0)
    func wiped(_ time: Double, from side: Transition.Side) -> Rect {
        wipe.time = time
        return wipe.wiped(from: side, view: Size(8, 4))
    }
    #expect([0.25, 0.5, 0.75, 1].map { wiped($0, from: .left) } == [Rect(x: 0, y: 0, width: 4, height: 4), Rect(x: 0, y: 0, width: 8, height: 4),
                                                                      Rect(x: 4, y: 0, width: 4, height: 4), Rect(x: 8, y: 0, width: 0, height: 4)])
    #expect(wiped(0.25, from: .right) == Rect(x: 4, y: 0, width: 4, height: 4) && wiped(0.75, from: .right) == Rect(x: 0, y: 0, width: 4, height: 4))
    #expect(wiped(0.25, from: .top) == Rect(x: 0, y: 0, width: 8, height: 2) && wiped(0.75, from: .bottom) == Rect(x: 0, y: 0, width: 8, height: 2))

    // An iris closes from the farthest corner to nothing at the switch, then opens.
    var iris = Change(duration: 1, style: .iris, color: 0)
    let radii = [0, 0.25, 0.5, 0.75].map { time in
        iris.time = time
        return iris.radius(around: [0, 0], view: Size(3, 4))
    }
    #expect(radii == [5, 2.5, 0, 2.5])

    // A dissolve switches at once, the old scene's last frame going over the next.
    Scene.transition(to: village, duration: 1, style: .dissolve)
    Scene.tick(0.25)
    #expect(Scene.current === village && village.updates == 1 && Scene.changing?.kept == 0.75 && Scene.changing?.switchTime == 0)

    Scene.transition(to: house, duration: 0, style: .iris) // no time for it: at once
    #expect(Scene.current === house && Scene.changing?.next == nil)
}

@MainActor @Test func anIrisClosesInACircleAndADissolveDropsPixelsInAPattern() throws {
    let screen = try canvas(Size(8, 8))
    let scene = Scene()
    let iris = Change(duration: 1, style: .iris, color: 0xFF0000, time: 0.25) // half closed, on the middle without `follow`
    let closing = try render(screen) {
        screen.fill(Rect(x: 0, y: 0, width: 8, height: 8), color: 0x00FF00)
        iris.draw(screen, over: scene)
    }
    #expect(colors(closing, width: 8) == ["rrrrrrrr", "rrrggrrr", "rrggggrr", "rggggggr", "rggggggr", "rrggggrr", "rrrggrrr", "rrrrrrrr"])

    screen.snapshot = try texture(.init(repeating: 0xFF00_00FF, count: 64), width: 8) // the old scene, all red
    let dissolve = Change(duration: 1, style: .dissolve, color: 0, time: 0.5) // half of it gone, a checkerboard in the 4x4 pattern
    #expect(colors(try render(screen) { dissolve.draw(screen, over: scene) }, width: 8).prefix(4) == ["r.r.r.r.", ".r.r.r.r", "r.r.r.r.", ".r.r.r.r"])
}

@MainActor @Test func darknessCoversTheWorldButWhereLightsLightItAndTheHUDStaysLit() throws {
    final class Room: Scene {
        override func draw(_ screen: Screen) {
            super.draw(screen)
            screen.fill(Rect(x: 0, y: 0, width: 1, height: 1), color: 0x00FF00) // the HUD
        }
    }
    let screen = try canvas(Size(8, 2))
    screen.textures["wall"] = try texture(.init(repeating: 0xFFFF_FFFF, count: 16), width: 8) // white
    screen.sheets["wall"] = .some(nil)
    let room = Room()
    let (wall, lamp) = (Entity(), Entity())
    wall.sprite = Sprite("wall")
    lamp.hitbox = Rect(x: 0, y: 0, width: 2, height: 2) // its middle, (4, 1), where it shines from
    lamp.light = Light(radius: 3, color: 0xFF0000)
    room.add(wall, at: .zero)
    room.add(lamp, at: [3, 0])
    room.darkness = 1
    let lit = try render(screen) { room.draw(screen) }
    let reds = lit[8..<16].map { Int($0 >> 16 & 0xFF) }
    #expect(reds == reds.reversed() && reds[0] == 0 && reds[1] < reds[2] && reds[2] < reds[3] && reds[3] > 200) // brightest in the middle
    #expect(lit.allSatisfy { $0 & 0xFF == 0 } && lit[0] == 0xFF00_FF00) // only red light, and the HUD as it is

    lamp.light = nil
    room.darkness = 0.5
    #expect(try render(screen) { room.draw(screen) }[8..<16].allSatisfy { (0xFF7F_7F7F...0xFF80_8080).contains($0) }) // gray
    (room.darkness, room.darknessColor) = (1, 0x0000FF)
    #expect(try render(screen) { room.draw(screen) }[9] == 0xFF00_00FF) // the night's blue

    var torch = Light(radius: 10, flicker: 0.2)
    let radii = (0..<60).map { step in
        torch.time = Double(step) / 60
        return torch.radius(seed: 7)
    }
    #expect(radii.allSatisfy { (8...10).contains($0) } && Set(radii).count == 60) // wavering, by up to a fifth
}

@MainActor @Test func aTransitionStartedDuringAnotherGoesOnFromHowFarTheViewIsCovered() {
    let (village, house, wood) = (Scene(), Scene(), Scene())
    Scene.current = village
    defer { (Scene.current, Scene.changing) = (Scene(), nil) }
    Scene.fade(to: house, duration: 1)
    for _ in 0..<6 { Scene.tick(0.125) } // past the switch, three quarters of the way: half covered again
    #expect(Scene.current === house && Scene.changing?.cover == 0.5)
    Scene.fade(to: wood, duration: 1) // darkening again from half covered, not jumping to none
    #expect(Scene.changing?.cover == 0.5 && Scene.changing?.next === wood)
    Scene.tick(0.125)
    #expect(Scene.changing?.cover == 0.75 && Scene.current === house)
    Scene.tick(0.125)
    #expect(Scene.changing?.cover == 1 && Scene.current === wood)
}

@MainActor @Test func aDissolveBreaksUpTheSceneAsTheUpdateThatStartedItLeftIt() throws {
    final class Title: Scene {
        var chosen = false
        override func update(_ dt: Double) {
            guard !chosen else { return }
            chosen = true // as a click on a choice does, in the update that starts the dissolve
            Scene.transition(to: Scene(), duration: 1, style: .dissolve)
        }
        override func draw(_ screen: Screen) {
            super.draw(screen)
            screen.fill(Rect(x: 0, y: 0, width: 2, height: 2), color: chosen ? 0x00FF00 : 0xFF0000)
        }
    }
    let loop = Loop(resolution: Size(2, 2), gpu: try #require(systemGPU()))
    Scene.current = Title()
    defer { (Scene.current, Scene.changing) = (Scene(), nil) }
    for now in [loop.last, loop.last + Loop.step] { // a frame before the choice, red, then the update that makes it
        let commands = try #require(loop.tick(at: now))
        commands.commit()
        commands.waitUntilCompleted()
    }
    let commands = try #require(loop.gpu.commands())
    let pixels = try #require(loop.gpu.buffer(length: 16))
    commands.copy(loop.screen.snapshot, to: pixels)
    commands.commit()
    commands.waitUntilCompleted()
    let snapped = Array(pixels.contents.bindMemory(to: UInt32.self).prefix(4))
    #expect(snapped == [UInt32](repeating: 0xFF00_FF00, count: 4) && Scene.changing?.snapped == true && Scene.changing?.old == nil)
}

@MainActor @Test func aFlashFadesOnAnEntitysOwnSpriteAsItsCommentSays() {
    final class Crab: Entity {
        override func update(_ dt: Double) {
            if let flash = sprite?.flash { sprite?.flash = max(0, flash - dt * 8) } // as `Sprite.flash`'s comment has it
        }
    }
    let crab = Crab()
    crab.sprite = Sprite("crab")
    crab.sprite?.flash = 1
    crab.update(0.0625)
    #expect(crab.sprite?.flash == 0.5)
}
