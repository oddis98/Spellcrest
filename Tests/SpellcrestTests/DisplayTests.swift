import Metal
import Testing
@testable import Spellcrest

private struct Plain: Game {
    var resolution: Size { Size(240, 135) }
    func start() -> Scene { Scene() }
}

private struct Shaped: Game {
    func resolution(for display: Display) -> Size { display.sideways ? Size(480, 328) : Size(328, 480) }
    func start() -> Scene { Scene() }
}

/// A game's canvas for the display it's on is its `resolution`, unless it says otherwise.
@Test @MainActor func aGameShapesItsCanvasForTheDisplayOnlyWhenItSays() {
    #expect(Plain().resolution(for: Display(width: 402, height: 874, top: 62, bottom: 34)) == Size(240, 135))
    #expect(Shaped().resolution(for: Display(width: 874, height: 402)) == Size(480, 328))
    #expect(Shaped().resolution(for: Display(width: 402, height: 874)) == Size(328, 480))
    #expect(Display(width: 874, height: 402).sideways && !Display(width: 402, height: 874).sideways)
}

/// Resized, the canvas is made again at the new size, at its scale; the same size keeps it.
@Test @MainActor func theCanvasFollowsItsSize() throws {
    let screen = Screen(size: Size(328, 480), gpu: try #require(systemGPU()), format: .bgra8)
    screen.resize(to: 2)
    screen.resize(canvas: Size(480, 328))
    #expect(screen.size == Size(480, 328) && screen.canvas.width == 960 && screen.canvas.height == 656)
    let canvas = screen.canvas
    screen.resize(canvas: Size(480, 328))
    #expect(screen.canvas === canvas)
}

private final class Laid: Scene {
    var olds: [Size] = []
    override func resized(from old: Size) { olds.append(old) }
}

/// The scene hears the canvas changed, and so does the one a transition is going to, each once.
@Test @MainActor func scenesHearTheCanvasChanged() {
    let (shown, next) = (Laid(), Laid())
    Scene.current = shown
    defer { (Scene.current, Scene.changing) = (Scene(), nil) }
    Scene.resized(from: Size(328, 480))
    #expect(shown.olds == [Size(328, 480)] && next.olds.isEmpty)
    Scene.transition(to: next, duration: 0.5, style: .fade)
    Scene.resized(from: Size(480, 328))
    #expect(shown.olds == [Size(328, 480), Size(480, 328)] && next.olds == [Size(480, 328)])
}
