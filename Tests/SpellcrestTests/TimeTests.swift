import Testing
@testable import Spellcrest

@MainActor @Test func aHeldSceneStandsStillWhileItsOwnUpdateAndItsShakeGoOn() {
    final class Held: Scene {
        var real: [Double] = []
        override func update(_ dt: Double) {
            real.append(dt)
            super.update(dt)
        }
    }
    final class Runner: Entity {
        var given: [Double] = []
        override func update(_ dt: Double) {
            given.append(dt)
            velocity = [60, 0]
            move(dt)
        }
    }
    let scene = Held(), runner = Runner()
    runner.sprite = Sprite("dot")
    scene.add(runner, at: .zero)
    scene.particles.burst(Emitter(life: 1...1, speed: 60...60, spread: 0), at: .zero, count: 1) // to the right
    scene.shake(1)
    scene.timeScale = 0 // a hit's hold
    for _ in 0..<6 { scene.advance(1.0 / 60) }
    #expect(scene.real == Array(repeating: 1.0 / 60, count: 6)) // its own update, in real time
    #expect(runner.given == Array(repeating: 0, count: 6) && runner.position == .zero && runner.sprite?.time == 0)
    #expect(scene.clock == 0 && scene.particles.x == [0] && scene.particles.age == [0])
    #expect(abs(scene.shaking.trauma - 0.9) < 1e-9 && scene.shook > 0.09) // the shake plays out

    scene.timeScale = 0.5 // slow motion
    for _ in 0..<6 { scene.advance(1.0 / 60) }
    #expect(abs(scene.clock - 0.05) < 1e-9 && abs((runner.sprite?.time ?? 0) - 0.05) < 1e-9)
    #expect(abs(Double(scene.particles.age[0]) - 0.05) < 1e-6 && abs(Double(scene.particles.x[0]) - 3) < 1e-4)
    #expect(abs(runner.position.x + runner.remainder.x - 3) < 1e-9) // 60 a second for a twentieth
}
