import MetalKit
import SpellcrestProtocol

/// The game loop: fixed 60 Hz updates, then the scene draws into the small canvas.
@MainActor final class Loop {
    nonisolated static let step = 1.0 / 60
    let screen: Screen
    let queue: MTLCommandQueue
    var last = CACurrentMediaTime()
    var pace = Pace()
    var checked = 0.0 // when the loop last looked for files that changed
    var paused = false {
        didSet { Music.paused = paused }
    }
    var steps = 0 // updates to run while paused

    init(resolution: Size, device: MTLDevice) {
        queue = device.makeCommandQueue()!
        screen = Screen(size: resolution, device: device, format: .bgra8Unorm)
        Input.canvas = resolution
        Sound.mixer.prepare() // so the first sounds don't wait for the audio engine
        Sound.readAhead() // in an app, the files of its sounds and objects, in the background, so none is waited for
        Scene.readAhead()
        screen.compileAhead() // and its shaders
    }

    /// Runs the updates that are due at `now`, when the frame will be on the screen, then draws the scene into the canvas
    /// on a new command buffer.
    func tick(at now: Double = CACurrentMediaTime()) -> MTLCommandBuffer? {
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

        guard let commands = queue.makeCommandBuffer() else { return nil }
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
    private func draw(_ scene: Scene, _ commands: MTLCommandBuffer, changing: Change? = nil) {
        let canvas = MTLRenderPassDescriptor()
        canvas.colorAttachments[0].texture = screen.canvas
        canvas.colorAttachments[0].loadAction = .clear
        canvas.colorAttachments[0].clearColor = clearColor(scene.background)
        screen.begin(commands, canvas)
        scene.draw(screen)
        changing?.draw(screen, over: scene)
        screen.end()
    }

    func update() {
        Input.poll()
        Scene.tick(Self.step)
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

/// Shows the game in its own window, the canvas scaled up by whole numbers, or on iOS, the app's screen, edge to edge.
/// A display link draws it as many times a second as the display shows (120 on ProMotion), rather than the view's own
/// timer, and says when each frame will be on the screen: the loop counts the time between frames from that, not from
/// when `draw` gets to run, which other work on the main thread, like a touch handled first, can make a few milliseconds
/// late; and the canvas is drawn at about the screen's scale (`canvasScale`), so what moves between the game's pixels
/// moves evenly, and between its 60 updates a second where frames come faster. On an iPhone or iPad it's a Metal display
/// link at 60 frames a second, which brings each frame's drawable: one taken after the frame could leave a launch a frame
/// behind the screen, every frame waiting about 12 ms for a drawable and showing 17 ms later. Faster, it's a
/// `CADisplayLink`, since the Metal one's frames reached an iPhone 16 Pro's screen only every other one at 120 Hz (iOS
/// 27.2), and the simulator keeps one too: the Metal one drew about 42 frames a second there, unevenly.
final class GameView: MTKView {
    let loop: Loop
    private var link: CADisplayLink? // on the Mac, in the simulator, and on a device faster than 60 Hz
    #if os(iOS)
    private var metalLink: CAMetalDisplayLink? // on a device at 60 Hz
    private var other = 0 // frames in a row at the other link's rate, as when Low Power Mode starts or stops
    #endif
    private var shows: Double? // when the frame being drawn will be on the screen, from `link` or `metalLink`

    init(resolution: Size) {
        let device = MTLCreateSystemDefaultDevice()!
        loop = Loop(resolution: resolution, device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        (isPaused, enableSetNeedsDisplay) = (true, false) // drawn by `link`
        #if os(macOS)
        colorspace = CGColorSpace(name: CGColorSpace.sRGB) // show asset colors exactly as they are in the PNG
        // Moves come as the window's first responder (`acceptsMouseMovedEvents`); this says when the mouse leaves.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        #elseif targetEnvironment(simulator)
        run(CADisplayLink(target: self, selector: #selector(refresh)))
        #else
        use(metal: false) // and at 60 Hz, a Metal one
        #endif
        #if os(iOS)
        // Stopped in the background, where iOS doesn't let an app use the GPU.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    required init(coder: NSCoder) { fatalError("GameView is created in code") }

    private func run(_ link: CADisplayLink) {
        #if os(macOS)
        let most = Float(window?.screen?.maximumFramesPerSecond ?? 60) // 144 on the development Mac's display
        #else
        let most: Float = 120
        #endif
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: most, preferred: most)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func refresh(_ link: CADisplayLink) {
        #if os(iOS) && !targetEnvironment(simulator)
        check(link.targetTimestamp - link.timestamp, metal: false)
        #endif
        shows = link.targetTimestamp
        draw()
    }

    #if os(iOS) && !targetEnvironment(simulator)
    /// A Metal display link, or a `CADisplayLink` for a display faster than 60 Hz: at 120 Hz its frames wait about 5 ms
    /// for a drawable, but all of them reach the screen, 18 to 25 ms after their update, where the Metal one's every other did.
    private func use(metal: Bool) {
        link?.invalidate()
        metalLink?.invalidate()
        (link, metalLink, other) = (nil, nil, 0)
        guard metal else { return run(CADisplayLink(target: self, selector: #selector(refresh))) }
        let link = CAMetalDisplayLink(metalLayer: layer as! CAMetalLayer)
        link.delegate = self
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120) // to see the display speed up
        link.add(to: .main, forMode: .common)
        metalLink = link
    }

    /// Switches links once the display has kept the other's rate half a second: 60 Hz for the Metal one, faster for the other.
    private func check(_ interval: Double, metal: Bool) {
        other = (interval > 1.0 / 90) != metal ? other + 1 : 0
        if other == 30 { DispatchQueue.main.async { self.use(metal: !metal) } }
    }
    #endif

    #if os(iOS)
    @objc private func background() { link?.isPaused = true; metalLink?.isPaused = true }
    @objc private func foreground() { link?.isPaused = false; metalLink?.isPaused = false }

    /// The view gives its layer a new drawable size only as it hands out drawables itself, and `metalLink` takes them from
    /// the layer: turned sideways, the game was drawn upright and squeezed onto the screen.
    override func layoutSubviews() {
        super.layoutSubviews()
        (layer as! CAMetalLayer).drawableSize = drawableSize
    }
    #else
    /// The display link of the screen the window is on, which follows it to another.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, link == nil { run(displayLink(target: self, selector: #selector(refresh))) }
    }
    #endif

    #if os(macOS)
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { Input.keys.insert(Int(event.keyCode)) }
    override func keyUp(with event: NSEvent) { Input.keys.remove(Int(event.keyCode)) }
    /// Shift comes as a change of the modifiers, not as a key going down: held while its own bit is in them.
    override func flagsChanged(with event: NSEvent) {
        let key = Int(event.keyCode)
        guard let bit = Input.shiftBits[key] else { return }
        if event.modifierFlags.rawValue & bit != 0 { Input.keys.insert(key) } else { Input.keys.remove(key) }
    }
    override func mouseDown(with event: NSEvent) { point(event, down: true) }
    override func mouseDragged(with event: NSEvent) { point(event, down: true) }
    override func mouseUp(with event: NSEvent) { point(event, down: false) }
    override func mouseMoved(with event: NSEvent) { point(event, down: false) }
    override func mouseExited(with event: NSEvent) { if NSEvent.pressedMouseButtons & 1 == 0 { Input.point(nil, down: false) } }

    /// The mouse, through the letterbox, in canvas pixels. The view's y goes up, the drawable's down.
    private func point(_ event: NSEvent, down: Bool) {
        let (point, scale, canvas) = (convert(event.locationInWindow, from: nil), drawableSize.width / bounds.width, loop.screen.size)
        let drawn = CGPoint(x: point.x * scale, y: (bounds.height - point.y) * scale)
        Input.point(pixel(at: drawn, in: letterbox(canvas, in: drawableSize), canvas: canvas), down: down)
    }
    #endif

    override func draw(_ dirtyRect: CGRect) { frame { currentDrawable } }

    /// The frame first, then a drawable to show it in: `link`'s taken now, held no longer than it takes to draw into it,
    /// or the one `metalLink` brought.
    private func frame(_ drawable: () -> CAMetalDrawable?) {
        #if os(iOS)
        let fill = true // the screen's edges
        #else
        let fill = false // whole numbers
        #endif
        loop.screen.resize(to: canvasScale(loop.screen.size, in: drawableSize, fill: fill))
        guard let commands = loop.tick(at: shows ?? CACurrentMediaTime()) else { return }
        defer { commands.commit() } // with or without a drawable, for the canvas a dissolve copies
        guard let drawable = drawable() else { return }
        #if os(iOS)
        if Input.hardware { for case let controls as TouchControls in subviews { controls.shown = false } }
        for case let controls as TouchControls in subviews { controls.aside = Input.touchControlsAside }
        #endif
        let window = MTLRenderPassDescriptor()
        window.colorAttachments[0].texture = drawable.texture
        (window.colorAttachments[0].loadAction, window.colorAttachments[0].storeAction) = (.clear, .store)
        window.colorAttachments[0].clearColor = clearColor
        // The drawable's own size: `metalLink`'s may be from before the screen turned.
        let size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let screen = loop.screen
        screen.begin(commands, window, screen.smooth)
        #if os(iOS)
        screen.encoder.setViewport(fit(screen.size, in: size, top: safeAreaInsets.top * size.height / max(bounds.height, 1)))
        #else
        screen.encoder.setViewport(letterbox(screen.size, in: size))
        #endif
        screen.whole(screen.canvas)
        screen.end()
        commands.present(drawable)
    }
}

#if os(iOS)
extension GameView: @preconcurrency CAMetalDisplayLinkDelegate {
    /// A frame for the screen, with the drawable it will show in and when (`metalLink` is on the main run loop).
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        #if !targetEnvironment(simulator)
        check(update.targetPresentationTimestamp - (shows ?? 0), metal: true)
        #endif
        shows = update.targetPresentationTimestamp
        frame { update.drawable }
    }
}
#endif

#if os(macOS)
/// Runs the game without a window and sends every frame to the editor that launched it, which shows it in its
/// preview. Keys pressed in the preview, and pause and step, come back the same way.
@MainActor final class EditorHost {
    let loop: Loop
    let channel: Channel
    let pixels: MTLBuffer // the canvas, copied out each frame

    init(resolution: Size, channel: Channel) {
        let device = MTLCreateSystemDefaultDevice()!
        loop = Loop(resolution: resolution, device: device)
        self.channel = channel
        pixels = device.makeBuffer(length: resolution.width * resolution.height * 4, options: .storageModeShared)!
    }

    // ponytail: copies the small canvas each frame (230 KB at 320x180); share an IOSurface if games outgrow it
    func frame() {
        guard let commands = loop.tick(), let blit = commands.makeBlitCommandEncoder() else { return }
        let (width, height) = (loop.screen.size.width, loop.screen.size.height)
        blit.copy(from: loop.screen.canvas, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: pixels, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        channel.send(.frame(width: width, height: height, pixels: Data(bytes: pixels.contents(), count: width * height * 4)))
    }

    func handle(_ message: Message) {
        switch message {
        case let .keys(keys): Input.keys = Set(keys)
        case let .pointer(x, y, down): Input.point([Double(x), Double(y)], down: down)
        case .pause: loop.paused = true
        case .resume: loop.paused = false
        case .step: loop.steps += 1
        case let .reload(path): print(Reloader.load(path)) // shows in the editor's console
        case .frame: break
        }
    }
}
#endif
