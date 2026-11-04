#if canImport(ImageIO)
import Foundation
import ImageIO

/// Which pixels of a PNG show (alpha above 0), row by row, and how wide it is; nil if it can't be read.
func opaquePixels(_ url: URL) -> (width: Int, pixels: [Bool])? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
          let data = context.data else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (image.width, UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height).map { $0 > 0 })
}

/// A PNG's pixels, 0xRRGGBBAA with straight alpha, and its width.
func readPixels(_ url: URL) throws -> (pixels: [UInt32], width: Int) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    let (width, height) = (image.width, image.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = (0..<width * height).map { i -> UInt32 in
        let a = UInt32(bytes[i * 4 + 3])
        guard a > 0 else { return 0 }
        func straight(_ c: UInt8) -> UInt32 { a == 255 ? UInt32(c) : min(255, (UInt32(c) * 255 + a / 2) / a) } // drawn premultiplied
        return straight(bytes[i * 4]) << 24 | straight(bytes[i * 4 + 1]) << 16 | straight(bytes[i * 4 + 2]) << 8 | a
    }
    return (pixels, width)
}
#endif
