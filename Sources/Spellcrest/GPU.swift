import Foundation

// What the engine asks of the GPU, whichever it is: Metal on the Mac, iPhone and iPad (Apple/MetalGPU.swift). It's
// close to Metal's own calls, and to SDL's GPU API, so the drawing code reads as it did: textures, pipelines made from
// the engine's shaders by name, render passes into up to three textures, draws, copies, and pixels read back. The
// resources are classes a backend subclasses, so the drawing code keeps and compares them as it did Metal's, and reads
// a texture's size without asking the GPU.

/// How a texture keeps its pixels.
enum PixelFormat: Sendable {
    /// 8 bits each of red, green, blue and alpha: images, the built-in font, people.
    case rgba8
    /// The same, blue first: the canvas, and the screen's drawable.
    case bgra8
    /// Half floats: the light maps, the bloom's and the bends' maps.
    case rgba16Float
    /// One channel of 8 bits: what's opaque, the clouds' and the fog's maps.
    case r8
}

/// A texture on the GPU: an image, the canvas, a light map.
class GPUTexture: @unchecked Sendable {
    let width: Int, height: Int, format: PixelFormat
    init(width: Int, height: Int, format: PixelFormat) { (self.width, self.height, self.format) = (width, height, format) }
}

/// A pipeline: a vertex and a fragment function, the formats of the textures it draws into, and how it blends.
class GPUPipeline: @unchecked Sendable {}

/// Compiled shaders: the engine's, or one of a game's own.
class GPULibrary: @unchecked Sendable {}

/// Bytes the GPU reads, vertices or instances, or bytes it copies a texture's pixels into for the CPU to read.
class GPUBuffer: @unchecked Sendable {
    /// What a buffer the CPU reads holds, once the commands that copied into it have completed.
    var contents: UnsafeRawBufferPointer { fatalError("a backend's buffer says") }
}

/// How a pipeline's colors are mixed with what's already in its targets: each of the source and the destination times
/// its factor, then added, the source taken from the destination, or the smaller of the two.
enum BlendFactor: Sendable { case zero, one, sourceAlpha, oneMinusSourceAlpha, destinationColor, destinationAlpha }
enum BlendOperation: Sendable { case add, reverseSubtract, min }

/// Where a pass draws, as a Metal pass descriptor says it: a texture for each of its colors, and what each holds as the
/// pass begins. A class, as a descriptor is, so a pass set aside while another draws (`Screen.Pass`) goes on from what
/// it drew, its load turned to `.load` as it's interrupted.
final class Targets {
    var colors: [Target]
    init(_ colors: [Target]) { self.colors = colors }
}

/// One of a pass's textures, and what it holds as the pass begins. Each keeps what's drawn into it.
struct Target {
    var texture: GPUTexture
    var load: Load
}

/// What a pass's texture holds as the pass begins: cleared to a color, what it held, or anything, for a pass that
/// draws over all of it.
enum Load: Equatable {
    case clear(red: Double, green: Double, blue: Double, alpha: Double)
    case load
    case dontCare
}

/// Where a pass draws on its textures, in their pixels from the top left.
struct Viewport: Equatable {
    var originX, originY, width, height: Double
}

/// A rectangle of a texture's pixels, to copy.
struct Region {
    var x, y, width, height: Int
}

/// The GPU, which makes what the engine draws with. Its pipelines can be made off the main thread, as the light maps'
/// are as the screen is made.
protocol GPU: AnyObject, Sendable {
    /// A texture the engine draws into and its shaders read: the canvas, a light map.
    func texture(_ format: PixelFormat, width: Int, height: Int) -> GPUTexture
    /// A texture of `pixels`, RGBA, row by row, that shaders read: a person, the built-in font.
    func texture(rgba pixels: UnsafeRawBufferPointer, width: Int, height: Int) -> GPUTexture?
    /// A texture of the PNG at `url`, its pixels as the file holds them, that shaders read: an image.
    func texture(contentsOf url: URL) throws -> GPUTexture
    /// A pipeline drawing with `vertex` and `fragment`, from the engine's shaders or a game's (`library`), into
    /// textures of `formats`, each blended the same way: `rgb`'s and `alpha`'s factors, with `operation`; those
    /// `masked` it leaves as they are.
    func pipeline(_ fragment: String, vertex: String, library: GPULibrary?, formats: [PixelFormat], rgb: (BlendFactor, BlendFactor),
                  alpha: (BlendFactor, BlendFactor), operation: (rgb: BlendOperation, alpha: BlendOperation), masked: [Int]) -> GPUPipeline
    /// A buffer holding `bytes`, which draws read.
    func buffer(_ bytes: UnsafeRawBufferPointer) -> GPUBuffer?
    /// A buffer of `length` bytes that a texture's pixels are copied into for the CPU to read.
    func buffer(length: Int) -> GPUBuffer?
    /// Commands to encode a frame's passes and copies on.
    func commands() -> GPUCommands?
    /// Compiles one of a game's shaders, `text` from the file at `path`, whose function is `name`, as `kind`, in the
    /// background: `done` has its library, or else what's wrong with it, as the compiler said it.
    func compile(_ text: String, name: String, path: String, kind: ShaderKind, done: @escaping @Sendable (GPULibrary?, String?) -> Void)
}

/// A frame's commands: passes and copies, in order, then committed to the GPU.
protocol GPUCommands: AnyObject {
    /// Begins a pass into `targets`, which draws until its encoder ends.
    func render(_ targets: Targets) -> GPURenderEncoder
    /// Copies all of `texture` into `other`, the same size and format.
    func copy(_ texture: GPUTexture, to other: GPUTexture)
    /// Copies `regions` of `texture` into the same places in `other`.
    func copy(_ texture: GPUTexture, to other: GPUTexture, regions: [Region])
    /// Copies an RGBA or BGRA texture's pixels, row by row, into `buffer` for the CPU to read once these complete.
    func copy(_ texture: GPUTexture, to buffer: GPUBuffer)
    func commit()
    func waitUntilCompleted()
}

/// What a pass draws with: a pipeline, buffers, bytes and textures at indices its shaders name, and draws of triangles.
protocol GPURenderEncoder: AnyObject {
    func setPipeline(_ pipeline: GPUPipeline)
    func setVertexBuffer(_ buffer: GPUBuffer?, offset: Int, index: Int)
    func setVertexBytes(_ bytes: UnsafeRawBufferPointer, index: Int)
    func setFragmentBytes(_ bytes: UnsafeRawBufferPointer, index: Int)
    func setVertexTexture(_ texture: GPUTexture, index: Int)
    func setFragmentTexture(_ texture: GPUTexture, index: Int)
    func setViewport(_ viewport: Viewport)
    /// Draws `vertices` corners' triangles.
    func draw(vertices: Int)
    /// Draws `vertices` corners' triangles, `instances` times.
    func draw(vertices: Int, instances: Int)
    func end()
}

extension GPU {
    /// A pipeline from the engine's shaders, or a game's, blending into each of `formats` alike.
    func pipeline(_ fragment: String, vertex: String = "spriteVertex", library: GPULibrary? = nil, formats: [PixelFormat],
                  rgb: (BlendFactor, BlendFactor), alpha: (BlendFactor, BlendFactor),
                  operation: (rgb: BlendOperation, alpha: BlendOperation) = (.add, .add), masked: [Int] = []) -> GPUPipeline {
        pipeline(fragment, vertex: vertex, library: library, formats: formats, rgb: rgb, alpha: alpha, operation: operation, masked: masked)
    }
}

extension GPURenderEncoder {
    func setVertexBytes<Value>(_ values: [Value], index: Int) { values.withUnsafeBytes { setVertexBytes($0, index: index) } }
    func setFragmentBytes<Value>(_ values: [Value], index: Int) { values.withUnsafeBytes { setFragmentBytes($0, index: index) } }
}
