import Foundation

/// The game loop: fixed 60 Hz updates, then the scene draws into the small canvas.
@MainActor final class Loop {
    nonisolated static let step = 1.0 / 60
    let screen: Screen
    let gpu: GPU
    var last = currentTime()
    var pace = Pace()
    var checked = 0.0 // when the loop last looked for files that changed
    var paused = false {
        didSet { Music.paused = paused }
    }
    var steps = 0 // updates to run while paused

    init(resolution: Size, gpu: GPU) {
        self.gpu = gpu
        screen = Screen(size: resolution, gpu: gpu, format: .bgra8)
        Input.canvas = resolution
        Sound.mixer.prepare() // so the first sounds don't wait for the audio engine
        Sound.readAhead() // in an app, the files of its sounds and objects, in the background, so none is waited for
        Scene.readAhead()
        screen.compileAhead() // and its shaders
    }

    /// Runs the updates that are due at `now`, when the frame will be on the screen, then draws the scene into the canvas
    /// on a new command buffer.
    func tick(at now: Double = currentTime()) -> GPUCommands? {
        let elapsed = now - last
        last = now
        if paused {
            for _ in 0..<steps { update() }
            (steps, pace) = (0, Pace())
        } else {
            for _ in 0..<pace.updates(after: elapsed) { update() }
        }
        screen.alpha = pace.alpha
        if assetsCanChange, now - checked >= 0.25 { // 4 times a second, but not in an app, whose files can't change
            checked = now
            screen.reloadChangedAssets()
            screen.reloadChangedShaders()
            Scene.current.tilemap?.reloadIfChanged()
            Music.restartIfChanged()
            Sound.forgetChanged()
        }

        guard let commands = gpu.commands() else { return nil }
        if let change = Scene.changing, change.style == .dissolve, !change.snapped {
            // The scene it leaves, drawn once more as its last update left it, so what that update changed, like a
            // choice clicked on a title, is what breaks up, not the frame before it.
            if let old = change.old { draw(old, commands) }
            screen.snap(commands)
            Scene.changing?.snapped = true
            Scene.changing?.old = nil
        }
        draw(Scene.current, commands, changing: Scene.changing)
        return commands
    }

    /// Draws `scene` into the canvas on `commands`, with the transition under way over it.
    private func draw(_ scene: Scene, _ commands: GPUCommands, changing: Change? = nil) {
        screen.begin(commands, Targets([Target(texture: screen.canvas, load: clearColor(scene.background))]))
        scene.draw(screen)
        changing?.draw(screen, over: scene)
        screen.end()
    }

    func update() {
        Input.poll()
        Scene.tick(Self.step)
    }

    /// Makes the canvas `size` pixels, as the game asked for the display it's shown on (`Game.resolution(for:)`), and tells
    /// the scene, and those a transition is between, to lay out again: the canvas changed, or only the room round it.
    func resize(to size: Size) {
        let old = screen.size
        if size != old, size.width > 0, size.height > 0 {
            screen.resize(canvas: size)
            Input.canvas = size
        }
        Scene.resized(from: old)
    }
}

/// How many of the game's 60 Hz updates a frame runs, from the time since the last frame. On a 60 Hz display, one for
/// each refresh since then, give or take 2 ms, so a frame drawn a little late, or a display a hair off 60 Hz, still runs
/// one; at other rates, as many as the time adds up to.
struct Pace {
    /// Time not simulated yet, kept half an update from where a frame would run one more or one less, so a frame a little
    /// early or late can't tip it either way. At 0, as a stall used to leave it, a frame 3 ms late ran two updates and the
    /// next one none: the picture stood still, then jumped.
    var lag = Loop.step / 2
    static let most = 15 // in a frame: after a stall, the game slows down for a moment rather than run a burst of updates
    /// How far the frame is from the last update to the next, from 0 to 1, as the entities are drawn (`Entity.drawnAt`):
    /// 1 on a 60 Hz display, where each frame shows its update as it is, and on a faster one how much of the next update's
    /// time has gone by, so a frame between two updates draws them part of the way.
    var alpha = 1.0

    mutating func updates(after elapsed: Double) -> Int {
        let refreshes = (elapsed / Loop.step).rounded()
        if refreshes >= 1, abs(elapsed - refreshes * Loop.step) < 0.002 {
            (lag, alpha) = (Loop.step / 2, 1)
            return min(Int(refreshes), Self.most)
        }
        lag = min(lag + elapsed, (Double(Self.most) + 0.5) * Loop.step)
        var due = 0
        while lag >= Loop.step {
            lag -= Loop.step
            due += 1
        }
        alpha = lag / Loop.step
        return due
    }
}
