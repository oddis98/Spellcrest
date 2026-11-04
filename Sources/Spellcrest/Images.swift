import Foundation

// Images are read by the platform: on Apple's, by MetalKit's loader for textures and ImageIO for their pixels
// (Apple/ImageIO.swift). MetalKit's loader gave exactly the pixels a decoder without color management gives, stb_image's,
// for every one of the 1,239 PNGs in the examples and the developer's games (Phase 64), so another platform's can be
// that and draw them the same.

/// A PNG's size, from its header; nil if it isn't one.
func pngSize(_ url: URL) -> Size? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let head = try? file.read(upToCount: 24), head.count == 24 else { return nil }
    let bytes = [UInt8](head)
    guard bytes[0..<8] == [137, 80, 78, 71, 13, 10, 26, 10], bytes[12..<16] == [73, 72, 68, 82] else { return nil } // the signature, then IHDR
    func number(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
    return Size(number(16), number(20))
}

extension Screen {
    /// A texture of the PNG at `url`.
    func image(_ url: URL) throws -> GPUTexture { try gpu.texture(contentsOf: url) }
}
