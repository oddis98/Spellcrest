import Foundation
import SpellcrestProtocol
import Testing
@testable import Spellcrest

@MainActor @Test func anAnimationThatDoesntLoopHoldsItsLastFrameAndSaysItsFinished() throws {
    let game = FileManager.default.temporaryDirectory.appending(path: "once-\(UUID())")
    try FileManager.default.createDirectory(at: game.appending(path: "Assets"), withIntermediateDirectories: true)
    let sheet = SheetFile(frameWidth: 1, frameHeight: 1, animations: ["swing": .init(frames: [3, 4, 5], fps: 10, loop: false),
                                                                       "walk": .init(frames: [0, 1], fps: 10)])
    try JSONEncoder().encode(sheet).write(to: game.appending(path: "Assets/hero.json"))
    let back = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath(game.path) // games load Assets/ relative to here
    defer { FileManager.default.changeCurrentDirectoryPath(back) }

    var hero = Sprite("hero")
    hero.play("swing")
    #expect(hero.frame == 0 && !hero.finished)
    hero.time = 0.25
    #expect(hero.frame == 2 && !hero.finished) // its last, showing
    hero.time = 0.31
    #expect(hero.frame == 2 && hero.finished) // held there, and over
    #expect(sheet.animations?["swing"]?.frame(at: 5) == 5) // the sheet's frame held, long after
    hero.play("swing", restart: true)
    #expect(hero.time == 0 && !hero.finished) // the same one, again from its start
    hero.play("walk")
    hero.time = 0.25
    #expect(hero.frame == 0 && !hero.finished) // a walk goes round, and never finishes
    hero.frame = 1
    #expect(hero.frame == 1) // gone to

    let scene = Scene(), runner = Entity()
    runner.sprite = Sprite("hero")
    runner.sprite?.play("swing")
    runner.sprite?.speed = 2
    scene.add(runner, at: .zero)
    for _ in 0..<8 { scene.update(1.0 / 60) } // two fifteenths of a second, at twice the speed: 2 frames in
    #expect(runner.sprite?.frame == 2)

    let looping = String(decoding: try JSONEncoder().encode(SheetFile.Animation(frames: [0], fps: 1)), as: UTF8.self)
    #expect(!looping.contains("loop")) // a sheet that says nothing of it writes as it did
}
