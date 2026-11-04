#if canImport(MetalKit)
import MetalKit

/// The platform's GPU: Metal's, on Apple's platforms; nil where there's none.
func systemGPU() -> GPU? { MetalGPU() }

/// The GPU through Metal, on the Mac, iPhone and iPad: the engine's shaders compiled at runtime, as it's made, so
/// building games doesn't need the offline Metal toolchain. Unchecked, for the texture loader, which images use on the
/// main thread only, as they're first drawn; the rest of Metal's objects are made to be used from any thread.
final class MetalGPU: GPU, @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary // the engine's shaders
    let loader: MTKTextureLoader

    init(device: MTLDevice) {
        self.device = device
        queue = device.makeCommandQueue()!
        loader = MTKTextureLoader(device: device)
        do { library = try device.makeLibrary(source: shaderCommon + shapingShaders + shaderEngine + lightShaders + particleShaders + glowShaders, options: nil) } catch {
            fatalError("Spellcrest: its shaders don't compile: \(error)")
        }
    }

    /// The system's GPU, nil where there's none.
    convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    func texture(_ format: PixelFormat, width: Int, height: Int) -> GPUTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format.metal, width: width, height: height, mipmapped: false)
        (descriptor.usage, descriptor.storageMode) = ([.renderTarget, .shaderRead], .private)
        return MetalTexture(device.makeTexture(descriptor: descriptor)!, format: format)
    }

    func texture(rgba pixels: UnsafeRawBufferPointer, width: Int, height: Int) -> GPUTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        guard width > 0, height > 0, let texture = device.makeTexture(descriptor: descriptor), let bytes = pixels.baseAddress else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return MetalTexture(texture, format: .rgba8)
    }

    func texture(contentsOf url: URL) throws -> GPUTexture {
        let texture = try loader.newTexture(URL: url, options: [.SRGB: false])
        return MetalTexture(texture, format: texture.pixelFormat == .rgba8Unorm ? .rgba8 : .bgra8) // PNGs load as BGRA
    }

    func pipeline(_ fragment: String, vertex: String, library: GPULibrary?, formats: [PixelFormat], rgb: (BlendFactor, BlendFactor),
                  alpha: (BlendFactor, BlendFactor), operation: (rgb: BlendOperation, alpha: BlendOperation), masked: [Int]) -> GPUPipeline {
        let library = library.map { unsafeDowncast($0, to: MetalLibrary.self).library } ?? self.library
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: vertex)
        pipeline.fragmentFunction = library.makeFunction(name: fragment)
        for (i, format) in formats.enumerated() {
            let color = pipeline.colorAttachments[i]!
            color.pixelFormat = format.metal
            color.isBlendingEnabled = true
            (color.sourceRGBBlendFactor, color.destinationRGBBlendFactor) = (rgb.0.metal, rgb.1.metal)
            (color.sourceAlphaBlendFactor, color.destinationAlphaBlendFactor) = (alpha.0.metal, alpha.1.metal)
            (color.rgbBlendOperation, color.alphaBlendOperation) = (operation.rgb.metal, operation.alpha.metal)
            if masked.contains(i) { color.writeMask = [] }
        }
        do { return MetalPipeline(try device.makeRenderPipelineState(descriptor: pipeline)) } catch {
            fatalError("Spellcrest: can't make the pipeline for \(fragment): \(error)")
        }
    }

    func buffer(_ bytes: UnsafeRawBufferPointer) -> GPUBuffer? {
        guard let base = bytes.baseAddress, let buffer = device.makeBuffer(bytes: base, length: bytes.count) else { return nil }
        return MetalBuffer(buffer)
    }

    func buffer(length: Int) -> GPUBuffer? { device.makeBuffer(length: length, options: .storageModeShared).map(MetalBuffer.init) }

    func commands() -> GPUCommands? { queue.makeCommandBuffer().map(MetalCommands.init) }

    func compile(_ text: String, name: String, path: String, kind: ShaderKind, done: @escaping @Sendable (GPULibrary?, String?) -> Void) {
        device.makeLibrary(source: shaderSource(text, name: name, path: path, kind: kind), options: nil) { library, error in
            done(library.map(MetalLibrary.init), error.map { "\($0.localizedDescription)" })
        }
    }
}

final class MetalTexture: GPUTexture, @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture, format: PixelFormat) {
        self.texture = texture
        super.init(width: texture.width, height: texture.height, format: format)
    }
}

final class MetalPipeline: GPUPipeline, @unchecked Sendable {
    let state: MTLRenderPipelineState
    init(_ state: MTLRenderPipelineState) { self.state = state }
}

final class MetalLibrary: GPULibrary, @unchecked Sendable {
    let library: MTLLibrary
    init(_ library: MTLLibrary) { self.library = library }
}

final class MetalBuffer: GPUBuffer, @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
    override var contents: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length) }
}

/// A frame's command buffer.
final class MetalCommands: GPUCommands {
    let buffer: MTLCommandBuffer
    init(_ buffer: MTLCommandBuffer) { self.buffer = buffer }

    func render(_ targets: Targets) -> GPURenderEncoder {
        let pass = MTLRenderPassDescriptor()
        for (i, target) in targets.colors.enumerated() {
            let color = pass.colorAttachments[i]!
            color.texture = metal(target.texture)
            switch target.load {
            case let .clear(red, green, blue, alpha):
                color.loadAction = .clear
                color.clearColor = MTLClearColor(red: red, green: green, blue: blue, alpha: alpha)
            case .load: color.loadAction = .load
            case .dontCare: color.loadAction = .dontCare
            }
            color.storeAction = .store
        }
        return MetalRenderEncoder(buffer.makeRenderCommandEncoder(descriptor: pass)!)
    }

    func copy(_ texture: GPUTexture, to other: GPUTexture) {
        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: metal(texture), to: metal(other))
        blit.endEncoding()
    }

    func copy(_ texture: GPUTexture, to other: GPUTexture, regions: [Region]) {
        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        for region in regions {
            let origin = MTLOrigin(x: region.x, y: region.y, z: 0)
            blit.copy(from: metal(texture), sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                      sourceSize: MTLSize(width: region.width, height: region.height, depth: 1), to: metal(other), destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: origin)
        }
        blit.endEncoding()
    }

    func copy(_ texture: GPUTexture, to buffer: GPUBuffer) {
        guard let blit = self.buffer.makeBlitCommandEncoder() else { return }
        let (width, height) = (texture.width, texture.height)
        blit.copy(from: metal(texture), sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: unsafeDowncast(buffer, to: MetalBuffer.self).buffer,
                  destinationOffset: 0, destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
    }

    func commit() { buffer.commit() }
    func waitUntilCompleted() { buffer.waitUntilCompleted() }
}

final class MetalRenderEncoder: GPURenderEncoder {
    let encoder: MTLRenderCommandEncoder
    init(_ encoder: MTLRenderCommandEncoder) { self.encoder = encoder }

    func setPipeline(_ pipeline: GPUPipeline) { encoder.setRenderPipelineState(unsafeDowncast(pipeline, to: MetalPipeline.self).state) }
    func setVertexBuffer(_ buffer: GPUBuffer?, offset: Int, index: Int) {
        encoder.setVertexBuffer(buffer.map { unsafeDowncast($0, to: MetalBuffer.self).buffer }, offset: offset, index: index)
    }
    func setVertexBytes(_ bytes: UnsafeRawBufferPointer, index: Int) { encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: index) }
    func setFragmentBytes(_ bytes: UnsafeRawBufferPointer, index: Int) { encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: index) }
    func setVertexTexture(_ texture: GPUTexture, index: Int) { encoder.setVertexTexture(metal(texture), index: index) }
    func setFragmentTexture(_ texture: GPUTexture, index: Int) { encoder.setFragmentTexture(metal(texture), index: index) }
    func setViewport(_ viewport: Viewport) {
        encoder.setViewport(MTLViewport(originX: viewport.originX, originY: viewport.originY, width: viewport.width, height: viewport.height,
                                        znear: 0, zfar: 1))
    }
    func draw(vertices: Int) { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices) }
    func draw(vertices: Int, instances: Int) { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices, instanceCount: instances) }
    func end() { encoder.endEncoding() }
}

/// A texture's Metal texture: every texture is one on Apple's platforms.
func metal(_ texture: GPUTexture) -> MTLTexture { unsafeDowncast(texture, to: MetalTexture.self).texture }

extension PixelFormat {
    var metal: MTLPixelFormat {
        switch self {
        case .rgba8: .rgba8Unorm
        case .bgra8: .bgra8Unorm
        case .rgba16Float: .rgba16Float
        case .r8: .r8Unorm
        }
    }
}

extension BlendFactor {
    var metal: MTLBlendFactor {
        switch self {
        case .zero: .zero
        case .one: .one
        case .sourceAlpha: .sourceAlpha
        case .oneMinusSourceAlpha: .oneMinusSourceAlpha
        case .destinationColor: .destinationColor
        case .destinationAlpha: .destinationAlpha
        }
    }
}

extension BlendOperation {
    var metal: MTLBlendOperation {
        switch self {
        case .add: .add
        case .reverseSubtract: .reverseSubtract
        case .min: .min
        }
    }
}
#endif
