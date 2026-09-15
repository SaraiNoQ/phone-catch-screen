import CoreImage
import Foundation

/// Renders a QR code into the terminal so you can point your phone at the screen
/// instead of typing an IP address.
///
/// Uses CoreImage's built-in `CIQRCodeGenerator`, so there is no third-party
/// dependency and no hand-rolled Reed-Solomon encoder. Two output rows are packed
/// into one text line with half-block glyphs, which makes each module roughly
/// square in a typical monospace cell — without that the code is visually
/// stretched and harder for a camera to read.
public enum TerminalQRCode {
    public enum Style {
        /// Assumes a light-on-dark terminal; dark modules are drawn with ink.
        case standard
        /// Swaps the glyphs for light-on-dark terminals that invert ink.
        case inverted
    }

    public static func render(_ content: String, quietZone: Int = 2, style: Style = .standard) -> String? {
        guard let matrix = matrix(for: content) else { return nil }
        return draw(matrix, quietZone: quietZone, style: style)
    }

    // MARK: - QR generation

    /// Returns a row-major `true = dark` bitmap of the QR modules.
    ///
    /// Note that CoreImage's generator emits its own one-module margin around the
    /// symbol, so the returned grid is two modules larger than the nominal QR
    /// version and already carries a quiet zone. That is harmless — the caller's
    /// `quietZone` is added on top, and a larger quiet zone only helps scanning.
    private static func matrix(for content: String) -> [[Bool]]? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(content.utf8), forKey: "inputMessage")
        // `M` tolerates ~15% damage. Enough for a terminal render, while keeping
        // the module count (and therefore the printed size) small.
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        // The generated image is one pixel per module; ask for exactly that.
        let extent = output.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let image = context.createCGImage(output, from: extent) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let bitmap = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        return (0..<height).map { row in
            (0..<width).map { column in pixels[row * width + column] < 128 }
        }
    }

    // MARK: - Rendering

    private static func draw(_ matrix: [[Bool]], quietZone: Int, style: Style) -> String {
        let darkGlyph: Character = style == .standard ? "█" : " "
        let lightGlyph: Character = style == .standard ? " " : "█"

        let size = matrix.count
        let padded = size + quietZone * 2
        // Pad to an even number of rows so the half-block pairing never runs off
        // the end of the matrix.
        let rows = padded + (padded % 2)

        func isDark(_ row: Int, _ column: Int) -> Bool {
            let r = row - quietZone
            let c = column - quietZone
            guard r >= 0, r < size, c >= 0, c < size else { return false }
            return matrix[r][c]
        }

        var out = ""
        var row = 0
        while row < rows {
            for column in 0..<padded {
                let top = isDark(row, column)
                let bottom = isDark(row + 1, column)
                switch (top, bottom) {
                case (true, true):
                    out.append(darkGlyph)
                case (true, false):
                    // Upper half block: ink on top only.
                    out.append(style == .standard ? "▀" : "▄")
                case (false, true):
                    out.append(style == .standard ? "▄" : "▀")
                case (false, false):
                    out.append(lightGlyph)
                }
            }
            out.append("\n")
            row += 2
        }
        return out
    }
}
