import Metal
import SpellcrestProtocol
import Testing
@testable import Spellcrest

@MainActor @Test func aBurstPutsOutItsCountFromItsPointWithinItsSpreadAndSpeed() {
    let particles = Particles()
    let sparks = Emitter(life: 1...1, speed: 10...20, angle: .pi / 2, spread: .pi / 2, area: 3, offset: [0, -4])
    particles.burst(sparks, at: [50, 50], count: 40)
    #expect(particles.count == 40)
    for i in 0..<40 {
        let (speed, way) = (hypot(particles.vx[i], particles.vy[i]), atan2(particles.vy[i], particles.vx[i]))
        #expect(speed >= 9.999 && speed <= 20.001)
        #expect(abs(way - .pi / 2) <= .pi / 4 + 0.001) // down, a quarter turn wide
        #expect(hypot(particles.x[i] - 50, particles.y[i] - 46) <= 3.001) // within 3 of the point less 4
        #expect(particles.sortY[i] == 50) // where it came out, its offset aside
    }
    particles.burst(sparks, at: .zero, count: 5, angle: 0, sortY: 9) // aimed right, drawn as at 9
    #expect((40..<45).allSatisfy { abs(atan2(particles.vy[$0], particles.vx[$0])) <= .pi / 4 + 0.001 && particles.sortY[$0] == 9 })
    particles.burst(sparks, at: .zero, count: 30_000)
    #expect(particles.count == Particles.most) // as many as there's room for
    particles.removeAll()
    #expect(particles.count == 0)
}

@MainActor @Test func particlesFallFadeAndSlowAsTheySayAndDieAtTheEndOfTheirLife() {
    let falling = Particles()
    falling.burst(Emitter(life: 1...1, speed: 10...10, angle: 0, spread: 0, gravity: [0, 60]), at: .zero, count: 1)
    for _ in 0..<30 { falling.update(1.0 / 60) } // half a second: 5 across, and down by 60 / 3600 * (1 + 2 + … + 30)
    #expect(abs(falling.x[0] - 5) < 0.001 && abs(falling.y[0] - 7.75) < 0.001 && abs(falling.vy[0] - 30) < 0.001)
    for _ in 0..<28 { falling.update(1.0 / 60) }
    #expect(falling.count == 1)
    for _ in 0..<3 { falling.update(1.0 / 60) }
    #expect(falling.count == 0) // its second is up

    let slowing = Particles()
    slowing.burst(Emitter(life: 2...2, speed: 10...10, spread: 0, drag: 2), at: .zero, count: 1)
    for _ in 0..<60 { slowing.update(1.0 / 60) }
    #expect(abs(slowing.vx[0] - 10 * exp(-2)) < 0.001) // most of its speed lost in a second

    #expect(Particles.color([0xFF0000], at: 0.7) == [1, 0, 0, 1])
    #expect(Particles.color([0xFF0000, 0x0000FF], at: 0) == [1, 0, 0, 1])
    #expect(Particles.color([0xFF0000, 0x0000FF], at: 0.5) == [0.5, 0, 0.5, 1])
    #expect(Particles.color([0xFF0000, 0x00FF00, 0x0000FF], at: 0.5) == [0, 1, 0, 1]) // evenly over its life
}

@MainActor @Test func theSameBurstsMakeTheSameParticlesAndAnEmitterAimedAnotherWayIsTheSameKind() {
    func run() -> [Float] {
        let particles = Particles()
        let motes = Emitter(life: 1...2, area: 5, jitter: 20)
        for step in 0..<20 {
            particles.burst(motes, at: [Double(step), 0], count: 3, angle: Double(step))
            particles.update(1.0 / 60)
        }
        return particles.x + particles.y
    }
    #expect(run() == run())

    let aimed = Particles()
    for turn in 0..<10 { aimed.burst(Emitter(angle: Double(turn)), at: .zero, count: 1) }
    #expect(aimed.kinds.count == 1) // how they come out isn't their kind
    let changing = Particles()
    for shade in 0..<100 { // each a new color, as a game might make them: those with none left let go
        changing.burst(Emitter(life: 0.01...0.01, colors: [UInt32(shade)]), at: .zero, count: 1)
        changing.update(0.02)
    }
    #expect(changing.kinds.count <= 64)
    changing.burst(Emitter(life: 1...1, colors: [7]), at: .zero, count: 1)
    #expect(changing.kinds[changing.kind[0]].colors == [7])
}

@MainActor @Test func anEntitysEmitterPutsOutItsRateFromItsMiddleWhereItStands() {
    let scene = Scene()
    let torch = Entity()
    torch.hitbox = Rect(x: 2, y: 4, width: 4, height: 4) // its middle: (4, 6) from its corner
    torch.emitter = Emitter(rate: 30, life: 5...5, speed: 0...0, offset: [0, -2])
    scene.add(torch, at: [10, 10])
    for _ in 0..<60 { scene.advance(1.0 / 60) }
    #expect(scene.particles.count == 30) // 30 a second
    #expect((0..<30).allSatisfy { scene.particles.x[$0] == 14 && scene.particles.y[$0] == 14 && scene.particles.sortY[$0] == torch.sortY })
    torch.emitter = nil
    for _ in 0..<60 { scene.advance(1.0 / 60) }
    #expect(scene.particles.count == 30)

    #expect(place(5, among: [1, 5, 5, 9]) == 3) // after those it ties with
    #expect(place(0, among: [1, 5]) == 0 && place(10, among: [1, 5]) == 2 && place(3, among: []) == 0)
}

@MainActor @Test func particlesThatGlowShineInTheDarkAndTheRestAreLitAsTheGroundIs() throws {
    let screen = try canvas(Size(8, 1))
    let room = Scene()
    let still = Emitter(life: 1...1, speed: 0...0, colors: [0xFF0000], fade: false)
    room.particles.burst(still, at: [1.5, 0.5], count: 1) // glowing red
    room.particles.burst(Emitter(life: 1...1, speed: 0...0, colors: [0x00FF00], fade: false, glows: false), at: [4.5, 0.5], count: 1)
    room.particles.burst(Emitter(life: 0...0, colors: [0x0000FF], fade: false), at: [6.5, 0.5], count: 1) // its life over as it's put out
    #expect(colors(try render(screen) { room.draw(screen) }, width: 8) == [".r..g.b."])
    room.darkness = 1
    #expect(colors(try render(screen) { room.draw(screen) }, width: 8) == [".r....b."]) // the green in the dark, the rest shining
    let lamp = Entity()
    lamp.hitbox = Rect(x: 0, y: 0, width: 1, height: 1)
    lamp.light = Light(radius: 3)
    room.add(lamp, at: [4, 0])
    let lit = try render(screen) { room.draw(screen) }
    #expect(lit[1] == 0xFFFF_0000 && lit[4] & 0xFF00 > 0x8000 && lit[4] & 0xFF_00FF == 0) // green, lit by the lamp
}

@MainActor @Test func particlesStandingDrawAmongTheEntitiesByWhereTheyCameOut() throws {
    let screen = try canvas(Size(4, 4))
    screen.textures["red"] = try texture(.init(repeating: 0xFF00_00FF, count: 16), width: 4)
    screen.sheets["red"] = .some(nil)
    let scene = Scene()
    scene.ySort = true
    let wall = Entity()
    (wall.sprite, wall.hitbox) = (Sprite("red"), Rect(x: 0, y: 0, width: 4, height: 4)) // standing at 4
    scene.add(wall, at: .zero)
    func dot(_ color: UInt32, _ depth: Emitter.Depth) -> Emitter {
        Emitter(life: 1...1, speed: 0...0, colors: [color], fade: false, glows: false, depth: depth)
    }
    scene.particles.burst(dot(0x00FF00, .standing), at: [1.5, 1.5], count: 1, sortY: 3) // behind the wall
    scene.particles.burst(dot(0x0000FF, .standing), at: [2.5, 2.5], count: 1, sortY: 4) // as far down as it is: in front
    scene.particles.burst(dot(0x0000FF, .ground), at: [0.5, 3.5], count: 1) // under it
    scene.particles.burst(dot(0x00FF00, .air), at: [3.5, 0.5], count: 1, sortY: 0) // over it
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 4) == ["rrrg", "rrrr", "rrbr", "rrrr"])
    scene.ySort = false
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 4) == ["rrrg", "rgrr", "rrbr", "rrrr"]) // standing over every entity
}

@MainActor @Test func anImageParticlePlaysItsFramesOverItsLife() throws {
    let screen = try canvas(Size(3, 2))
    screen.textures["puff"] = try texture([0xFF00_00FF, 0xFF00_00FF, 0xFFFF_0000, 0xFFFF_0000], width: 4) // red, then blue, 2 by 1 each
    screen.sheets["puff"] = SheetFile(frameWidth: 2, frameHeight: 1)
    let scene = Scene()
    scene.particles.burst(Emitter(life: 1...1, speed: 0...0, fade: false, image: ImageName("puff"), glows: false), at: [1.5, 0.5], count: 1)
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 3) == ["rr.", "..."]) // its middle on the point
    for _ in 0..<35 { scene.advance(1.0 / 60) }
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 3) == ["bb.", "..."]) // past half its life
}

@MainActor @Test func rainFallsInTheWorldWhereverTheViewIsAndSnowDriftsDown() throws {
    let screen = try canvas(Size(64, 48))
    let scene = Scene()
    scene.clock = 3.25
    #expect(try render(screen) { scene.draw(screen) }.allSatisfy { $0 == 0xFF00_0000 }) // no weather
    scene.weather = Weather(.rain, wind: .zero)
    let here = try render(screen) { scene.draw(screen) }
    let wet = here.filter { $0 != 0xFF00_0000 }.count
    #expect(wet > 30 && wet < 64 * 48 / 4) // streaks, and splashes, over a part of the view
    #expect(try render(screen) { scene.draw(screen) } == here) // the same for the same time
    scene.camera = [10, 256] // a pattern 256 pixels square
    let along = try render(screen) { scene.draw(screen) }
    #expect((0..<48).allSatisfy { row in Array(along[row * 64..<row * 64 + 54]) == Array(here[row * 64 + 10..<row * 64 + 64]) }) // in the world
    scene.clock += 0.1
    #expect(try render(screen) { scene.draw(screen) } != along) // falling

    scene.weather = Weather(.snow, amount: 2)
    let snowing = try render(screen) { scene.draw(screen) }.filter { $0 != 0xFF00_0000 }.count
    #expect(snowing > 10 && snowing < 64 * 48 / 4)
}

@MainActor @Test func aFastSparkStreaksBehindItOnWholePixelsAndASlowOneIsADot() throws {
    let screen = try canvas(Size(8, 1))
    let scene = Scene()
    let spark = Emitter(life: 1...1, speed: 100...100, spread: 0, colors: [0xFF0000], fade: false, glows: false, streak: 0.03)
    scene.particles.burst(spark, at: [5.5, 0.5], count: 1) // 3 pixels behind it, fading
    let drawn = try render(screen) { scene.draw(screen) }
    #expect(colors(drawn, width: 8) == ["..???r.."])
    #expect(drawn[2] & 0xFF0000 < drawn[3] & 0xFF0000 && drawn[3] & 0xFF0000 < drawn[4] & 0xFF0000) // fading toward its tail
    scene.particles.removeAll()
    scene.particles.burst(Emitter(life: 1...1, speed: 10...10, spread: 0, colors: [0xFF0000], fade: false, glows: false, streak: 0.03),
                          at: [5.5, 0.5], count: 1)
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 8) == [".....r.."]) // too slow to streak
}

@MainActor @Test func anEmberShrinksByWholePixelsOverItsLife() throws {
    let screen = try canvas(Size(5, 5))
    let scene = Scene()
    scene.particles.burst(Emitter(life: 1...1, speed: 0...0, colors: [0xFF0000], fade: false, size: 3, glows: false, endSize: 1),
                          at: [2.5, 2.5], count: 1)
    func red() throws -> Int { try render(screen) { scene.draw(screen) }.filter { $0 == 0xFFFF_0000 }.count }
    #expect(try red() == 9) // 3 square as it's born
    for _ in 0..<30 { scene.advance(1.0 / 60) }
    #expect(try red() == 4) // 2 square half way
    for _ in 0..<29 { scene.advance(1.0 / 60) }
    #expect(try red() == 1) // 1 as it dies
}

@MainActor @Test func anImageParticleSpinsByQuarterTurns() throws {
    let screen = try canvas(Size(3, 3))
    screen.textures["chip"] = try texture([0xFF00_00FF, 0xFFFF_0000], width: 2) // red, then blue, beside it
    screen.sheets["chip"] = .some(nil)
    let scene = Scene()
    let chips = Emitter(life: 1...1, speed: 0...0, fade: false, image: ImageName("chip"), glows: false, spin: 4) // a quarter in a quarter second
    scene.particles.burst(chips, at: [1.5, 1.5], count: 1)
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 3) == ["...", "rb.", "..."])
    for _ in 0..<16 { scene.advance(1.0 / 60) }
    #expect(colors(try render(screen) { scene.draw(screen) }, width: 3) == [".r.", ".b.", "..."]) // a quarter clockwise: on its side
}
