import Foundation

/// UIKit's `.artwork` files, as iOS 6 has them: little-endian, an image
/// count and the offset of the images' descriptors, then each image's
/// name offset (a NUL-terminated string); each descriptor is 12 bytes —
/// flags (32-bit), width and height (16-bit), and the offset of the
/// pixels, 4 bytes each, rows unpadded. UIKit maps the file and makes
/// images straight from those offsets, so an image can be moved to the
/// end of the file without touching the others.
enum UIKitArtwork {
    enum ArtworkError: Error { case malformed(String), missingImage(String) }

    /// Replaces image `name` with itself repeated out to `width` by
    /// `height` pixels (whole multiples of its size).
    static func tile(image name: String, in path: String, toWidth width: Int, height: Int, builder: RootFilesystemBuilder) throws {
        var bytes = try builder.contents(of: path)
        func word(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24 }
        func half(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func put(_ value: Int, at offset: Int, size: Int) {
            for byte in 0..<size { bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        guard bytes.count >= 8 else { throw ArtworkError.malformed(path) }
        let count = word(0), descriptors = word(4)
        guard count > 0, 8 + 4 * count <= bytes.count, descriptors + 12 * count <= bytes.count else { throw ArtworkError.malformed(path) }
        let wanted = Array(name.utf8) + [0]
        for index in 0..<count {
            let nameOffset = word(8 + 4 * index)
            guard nameOffset + wanted.count <= bytes.count, Array(bytes[nameOffset..<(nameOffset + wanted.count)]) == wanted else { continue }
            let descriptor = descriptors + 12 * index
            let tileWidth = half(descriptor + 4), tileHeight = half(descriptor + 6), pixels = word(descriptor + 8)
            guard tileWidth > 0, tileHeight > 0, width % tileWidth == 0, height % tileHeight == 0, width <= 0xFFFF, height <= 0xFFFF,
                  pixels + tileWidth * tileHeight * 4 <= bytes.count else { throw ArtworkError.malformed(name) }
            var tiled = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let from = pixels + ((y % tileHeight) * tileWidth + x % tileWidth) * 4
                    for byte in 0..<4 { tiled[(y * width + x) * 4 + byte] = bytes[from + byte] }
                }
            }
            while bytes.count % 16 != 0 { bytes.append(0) }
            let moved = bytes.count
            bytes += tiled
            put(width, at: descriptor + 4, size: 2)
            put(height, at: descriptor + 6, size: 2)
            put(moved, at: descriptor + 8, size: 4)
            try builder.replaceContents(of: path, with: bytes)
            return
        }
        throw ArtworkError.missingImage(name)
    }
}
