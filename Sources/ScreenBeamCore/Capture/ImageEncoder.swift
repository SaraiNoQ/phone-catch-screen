import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales and encodes a captured `CGImage` for transport.
///
/// The raw frame from a Retina display is roughly 3000×2000×4 bytes (~24 MB).
/// Encoding it at native size over Wi-Fi to a phone is wasteful, so the long edge
/// is capped (default 1600 px) before compression — a 4–8× payload reduction
/// with no meaningful loss of legibility on a phone screen.
public enum ImageEncoder {
    public struct Output {
        public let data: Data
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    public static func encode(
        _ image: CGImage,
        format: Shot.Format,
        quality: Double,
        maxLongEdge: Int
    ) throws -> Output {
        let scaled = try downscale(image, maxLongEdge: maxLongEdge)

        let type: UTType = (format == .png) ? .png : .jpeg
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw CaptureError.encodingFailed("无法创建 \(format.rawValue) 编码器")
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            // Clamp defensively: a hand-edited config with quality 7.0 would
            // otherwise make ImageIO produce a broken file.
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1.0)
        }
        CGImageDestinationAddImage(destination, scaled, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.encodingFailed("写入 \(format.rawValue) 数据失败")
        }

        return Output(
            data: buffer as Data,
            pixelWidth: scaled.width,
            pixelHeight: scaled.height
        )
    }

    /// Returns the original image when it already fits, avoiding a pointless
    /// redraw (and the associated colour-space conversion).
    private static func downscale(_ image: CGImage, maxLongEdge: Int) throws -> CGImage {
        guard maxLongEdge > 0 else { return image }

        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }

        let ratio = Double(maxLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))

        // sRGB + premultiplied-last matches what ScreenCaptureKit hands us and
        // keeps the JPEG from picking up a colour cast on wide-gamut displays.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CaptureError.encodingFailed("无法创建缩放上下文")
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let scaled = context.makeImage() else {
            throw CaptureError.encodingFailed("缩放后无法生成图像")
        }
        return scaled
    }
}
