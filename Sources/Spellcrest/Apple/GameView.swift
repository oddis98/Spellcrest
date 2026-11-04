#if canImport(MetalKit)
import MetalKit
#if os(iOS)
import UIKit
#endif

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
    #if os(iOS)
    private var shown: Display? // the display as the game last heard of it
    #endif

    init(resolution: Size) {
        let device = MTLCreateSystemDefaultDevice()!
        loop = Loop(resolution: resolution, gpu: MetalGPU(device: device))
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
        fitCanvas()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        fitCanvas()
    }

    /// The canvas the game asks for the display as it is now, its bounds and safe area (`Game.resolution(for:)`): as the
    /// view is first laid out, which is the first time iOS says how the game is held and what room it leaves, and again
    /// whenever either changes, as it turns, a foldable opens or the safe area moves, which iOS may say a moment after the
    /// bounds. The scene hears of each (`Scene.resized(from:)`).
    private func fitCanvas() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let insets = safeAreaInsets
        let display = Display(width: bounds.width, height: bounds.height, top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
        guard display != shown else { return }
        shown = display
        loop.resize(to: GameApp.game?.resolution(for: display) ?? Input.canvas)
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
        guard let commands = loop.tick(at: shows ?? currentTime()) else { return }
        defer { commands.commit() } // with or without a drawable, for the canvas a dissolve copies
        guard let drawable = drawable() else { return }
        #if os(iOS)
        if Input.hardware { for case let controls as TouchControls in subviews { controls.shown = false } }
        for case let controls as TouchControls in subviews { (controls.aside, controls.layout) = (Input.touchControlsAside, Input.touchLayout) }
        #endif
        let window = Targets([Target(texture: MetalTexture(drawable.texture, format: .bgra8),
                                     load: .clear(red: clearColor.red, green: clearColor.green, blue: clearColor.blue, alpha: clearColor.alpha))])
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
        unsafeDowncast(commands, to: MetalCommands.self).buffer.present(drawable)
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
#endif
