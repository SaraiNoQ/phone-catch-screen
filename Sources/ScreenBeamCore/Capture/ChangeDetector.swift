import CoreGraphics
import Foundation

/// Cheap "did the screen actually change?" test used by the watch loop.
///
/// The frame is reduced to a 32×32 grayscale thumbnail and compared against the
/// previous one by mean absolute difference. That is far cheaper than hashing
/// full-resolution pixels and, unlike an exact hash, tolerates the cursor blink
/// and sub-pixel animation that would otherwise make every frame look "new".
public enum ChangeDetector {
    public static let gridSize = 32

    public struct Signature: Sendable {
        public let gray: [UInt8]
        public let size: Int
    }

    public static func signature(of image: CGImage, size: Int = gridSize) -> Signature? {
        var buffer = [UInt8](repeating: 0, count: size * size)

        let created: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: size,
                      height: size,
                      bitsPerComponent: 8,
                      bytesPerRow: size,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }

            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }

        guard created else { return nil }
        return Signature(gray: buffer, size: size)
    }

    /// Normalised mean absolute difference in `0...1`.
    public static func difference(_ lhs: Signature, _ rhs: Signature) -> Double {
        guard lhs.size == rhs.size, lhs.gray.count == rhs.gray.count, !lhs.gray.isEmpty else {
            return 1.0
        }
        var total = 0
        for index in lhs.gray.indices {
            total += abs(Int(lhs.gray[index]) - Int(rhs.gray[index]))
        }
        return Double(total) / Double(lhs.gray.count * 255)
    }
}
