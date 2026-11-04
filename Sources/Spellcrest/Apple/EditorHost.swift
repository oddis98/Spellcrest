#if os(macOS)
import Foundation
import SpellcrestProtocol

/// Runs the game without a window and sends every frame to the editor that launched it, which shows it in its
/// preview. Keys pressed in the preview, and pause and step, come back the same way.
@MainActor final class EditorHost {
    let loop: Loop
    let channel: Channel
    let pixels: GPUBuffer // the canvas, copied out each frame

    init(resolution: Size, channel: Channel) {
        let gpu = systemGPU()!
        loop = Loop(resolution: resolution, gpu: gpu)
        self.channel = channel
        pixels = gpu.buffer(length: resolution.width * resolution.height * 4)!
    }

    // ponytail: copies the small canvas each frame (230 KB at 320x180); share an IOSurface if games outgrow it
    func frame() {
        guard let commands = loop.tick() else { return }
        let (width, height) = (loop.screen.size.width, loop.screen.size.height)
        commands.copy(loop.screen.canvas, to: pixels)
        commands.commit()
        commands.waitUntilCompleted()
        channel.send(.frame(width: width, height: height, pixels: Data(pixels.contents.prefix(width * height * 4))))
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
