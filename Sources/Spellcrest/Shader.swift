import Foundation

/// A shader in the game's `Assets`, by its `.metal` file's name: `Shader(.ripple)`. See `ImageName`, which says how
/// it's saved too.
public struct ShaderName: Hashable, Sendable, Codable {
    /// The file's name, without ".metal", which is its function's too.
    public let name: String
    /// The shader called `name`, for one that comes from data.
    public init(_ name: String) { self.name = name }
    /// Reads one saved as its name.
    public init(from decoder: Decoder) throws { name = try decoder.singleValueContainer().decode(String.self) }
    /// Saves it as its name.
    public func encode(to encoder: Encoder) throws { try save(name, to: encoder) }
}

/// One of the game's own shaders, `Assets/Shaders/<name>.metal`, and up to 16 numbers for it. Its file holds a Metal
/// function named as the file, as SwiftUI's shaders are:
/// - A color shader, `half4 name(float2 position, half4 color, Values values)`, goes on a sprite (`Sprite.shader`) and
///   makes each of its pixels' colors from the color it would have, its alpha apart; `position` is where the pixel is in
///   the sprite's frame.
/// - A layer shader, `half4 name(float2 position, Layer layer, Values values)`, goes on the picture (`Scene.effects`)
///   and makes each of its pixels from the picture so far, `layer.sample(position)`; `position` is where it is in the view.
///   It runs for every pixel of the canvas at the screen's scale, 2.8 million for a game 320 by 180 drawn at 7 times, so
///   one that changes only part of the picture returns `layer.sample(position)` early everywhere else; to move the
///   picture round a point, a `Bend` costs less still, drawn only where it is.
///
/// Positions are in the game's pixels, between them where the canvas is drawn bigger. `values[0]` to `values[15]` are
/// the numbers, `values.time` the scene's time in seconds and `values.size` the canvas's size; `noise`, `fbm`,
/// `dither` and `luma` are there to use. It compiles in the background as it's first used, or in an app as the game
/// starts, and where files can change, again when its file does. Until then, and if it doesn't compile, what it's on
/// draws without it, and the console says why: `<file>:<line>:<column>: error: <message>`.
public struct Shader: Sendable, Equatable {
    /// Which of the game's shaders it is.
    public var name: ShaderName
    /// The numbers it's given, `values[0]` to `values[15]` in Metal; those past 16 are left out.
    public var values: [Double]

    /// One of the game's shaders with numbers for it: `Shader(.ripple, [x, y, age])`.
    public init(_ name: ShaderName, _ values: [Double] = []) { (self.name, self.values) = (name, values) }

    /// A shader named in a string.
    @_disfavoredOverload public init(_ name: String, _ values: [Double] = []) { self.init(ShaderName(name), values) }
}

/// What a game's shader is used as: on a sprite, or on the picture.
enum ShaderKind: Sendable { case color, layer }

struct ShaderKey: Hashable {
    let name: String
    let kind: ShaderKind
}

/// A game's shader as it's compiled: its pipeline (and for a sprite that glows, another) once it has, nil if it didn't,
/// when its file last changed as it was read, and whether it last failed.
struct Compiled {
    var state: GPUPipeline?
    var glowing: GPUPipeline?
    var modified: Date?
    var compiling = true
    var failed = false
}

extension Screen {
    /// A game's shader's pipelines as `kind` once it has compiled; nil until then, if it doesn't, or without a file.
    /// Asked for the first time, it starts compiling.
    func shader(_ name: String, _ kind: ShaderKind) -> (state: GPUPipeline, glowing: GPUPipeline?)? {
        let key = ShaderKey(name: name, kind: kind)
        guard let compiled = shaders[key] else {
            compile(key)
            return nil
        }
        return compiled.state.map { ($0, compiled.glowing) }
    }

    /// Compiles a game's shader in the background, keeping what it drew with until it's done: the file read now, made
    /// whole (`shaderSource`), then its library and its pipelines.
    func compile(_ key: ShaderKey) {
        let url = assetURL("\(key.name).metal")
        let modified = modificationDate(url)
        shaders[key, default: Compiled()].modified = modified
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            shaders[key] = Compiled(modified: modified, compiling: false, failed: true)
            if warned.insert("\(key.name).metal").inserted { print("Spellcrest: Assets has no \(key.name).metal") }
            return
        }
        shaders[key]?.compiling = true
        let (format, gpu) = (canvas.format, self.gpu)
        gpu.compile(text, name: key.name, path: url.path, kind: key.kind) { library, problem in
            // Its pipelines are made on a queue of their own once the compiler's callback is done with: made in Metal's
            // callback, a pipeline can wait on the queue the callback runs on, which trapped in the iOS 27 simulator now
            // and then (`__DISPATCH_WAIT_FOR_QUEUE__`) when two shaders compiled at once, as an app's do as it starts.
            DispatchQueue.global(qos: .userInitiated).async {
                var made: Compiled?
                if let library {
                    let blend: (BlendFactor, BlendFactor) = key.kind == .color ? (.sourceAlpha, .oneMinusSourceAlpha) : (.one, .zero)
                    let entry = key.kind == .color ? "spellcrestColor" : "spellcrestLayer"
                    let vertex = key.kind == .color ? "litVertex" : "spriteVertex" // a sprite's lit as the engine's are
                    made = Compiled(state: gpu.pipeline(entry, vertex: vertex, library: library, formats: [format], rgb: blend,
                                                        alpha: key.kind == .color ? (.one, .oneMinusSourceAlpha) : (.one, .zero)),
                                    glowing: key.kind == .color ? gpu.pipeline(entry, vertex: vertex, library: library, formats: [format], rgb: (.one, .one),
                                                                               alpha: (.zero, .one)) : nil)
                }
                let handed = Handed(value: made)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Its errors, or that it compiles once more after them, so the editor drops errors printed for an
                        // older save, which may finish compiling after the one that fixed them.
                        if let problem { print(problem.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        else if self.shaders[key]?.failed == true { print("Spellcrest: \(url.path) compiles again") }
                        var compiled = handed.value ?? Compiled()
                        (compiled.modified, compiled.compiling, compiled.failed) = (modified, false, problem != nil)
                        self.shaders[key] = compiled
                    }
                }
            }
        }
    }

    /// Compiles again the game's shaders whose files changed, saved by the editor.
    func reloadChangedShaders() {
        for (key, compiled) in shaders where !compiled.compiling && modificationDate(assetURL("\(key.name).metal")) != compiled.modified { compile(key) }
    }

    /// In an app, compiles its shaders in the background as the game starts, as `Sound.readAhead` reads its sounds, so
    /// none waits until it's first drawn: each as a color shader, or a layer shader if its function takes a `Layer`.
    func compileAhead() {
        guard !assetsCanChange else { return }
        for name in bundledNames(["metal"]) {
            guard let text = try? String(contentsOf: assetURL("\(name).metal"), encoding: .utf8) else { continue }
            compile(ShaderKey(name: name, kind: shaderKind(text, name: name)))
        }
    }

    /// What a game's shader is given: the scene's time, the canvas's size, and its numbers (`Values` in the shaders).
    func values(_ shader: Shader) -> [Float] {
        var values = [Float(time), 0, Float(size.width), Float(size.height)] + [Float](repeating: 0, count: 16)
        for (i, value) in shader.values.prefix(16).enumerated() { values[4 + i] = Float(value) }
        return values
    }

    /// Runs the scene's effects on the picture in turn, each drawing the canvas into the spare through its layer shader,
    /// which then becomes the canvas.
    func apply(_ effects: [Shader]) {
        for effect in effects {
            guard let made = shader(effect.name.name, .layer) else { continue }
            let canvas = current!, picture = self.canvas
            go(Pass(targets: Targets([Target(texture: spare, load: .dontCare)]), usual: made.state, grid: Double(scale), size: size))
            queue(picture, [0, 0, Float(size.width), Float(size.height)], values: values(effect))
            end()
            turnOver()
            canvas.targets.colors[0] = Target(texture: self.canvas, load: .load)
            go(canvas)
        }
    }
}

/// Whether a shader file's function, named as the file, takes a `Layer`, so it goes on the picture, or else a color.
func shaderKind(_ text: String, name: String) -> ShaderKind {
    guard let signature = text.range(of: "\\b\(name)\\s*\\([^)]*\\)", options: .regularExpression) else { return .color }
    return text[signature].range(of: "\\bLayer\\b", options: .regularExpression) == nil ? .color : .layer
}
