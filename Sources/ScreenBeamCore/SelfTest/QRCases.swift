import CoreGraphics
import CoreImage
import Foundation

/// The terminal QR code is hand-rendered from a module bitmap, and its failure
/// mode is silent: an inverted or misaligned code still *looks* like a QR code,
/// but no camera reads it. These cases decode the rendered ASCII back into an
/// image so a wrong render fails loudly.
enum QRCases {
    /// A payload shaped like the real thing — same length, same character set,
    /// same query layout — so the render is exercised at a realistic QR version.
    /// The token is an obvious placeholder: a real one must never be committed,
    /// and this file had exactly that problem once.
    static let payload = "http://192.168.1.23:8787/?token=deadbeefcafebabe0123456789abcdef"

    static let all: [(String, () throws -> Void)] = [
        ("二维码可被解码器读回原文", {
            let art = try checkUnwrap(TerminalQRCode.render(payload), "render 输出")
            let grid = try checkUnwrap(moduleGrid(from: art), "ASCII 画布解析")

            let bitmap = try checkUnwrap(Self.image(from: grid), "位图重建")
            let detector = try checkUnwrap(
                CIDetector(
                    ofType: CIDetectorTypeQRCode,
                    context: nil,
                    options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
                ),
                "CIDetector"
            )

            let features = detector.features(in: CIImage(cgImage: bitmap)).compactMap {
                $0 as? CIQRCodeFeature
            }
            try checkEqual(features.count, 1, "识别到的二维码数量")
            try checkEqual(features.first?.messageString, payload, "解码内容")
        }),

        // A QR camera often tolerates inversion, so the decode case above would
        // not catch a fully inverted render — it would decode either way. The
        // finder pattern is what actually pins the polarity down.
        //
        // The pattern is located rather than hardcoded at an offset, because
        // CoreImage's generator bakes in its own one-module margin, so absolute
        // positions depend on an implementation detail we do not control.
        ("定位图案极性正确（未被反色）", {
            let art = try checkUnwrap(TerminalQRCode.render(payload, quietZone: 2), "render 输出")
            let grid = try checkUnwrap(moduleGrid(from: art), "ASCII 画布解析")
            let origin = try checkUnwrap(findFinderOrigin(in: grid), "未找到定位图案")

            // The canonical 7×7 finder: a dark ring, a light gap, a dark core.
            let expected = [
                "#######",
                "#.....#",
                "#.###.#",
                "#.###.#",
                "#.###.#",
                "#.....#",
                "#######",
            ]

            func dump() -> String {
                guard origin.row + 8 < grid.count, origin.column + 8 < grid[0].count else { return "" }
                return "\n" + (origin.row - 1...origin.row + 8).map { row in
                    "        " + grid[row][origin.column - 1...origin.column + 8]
                        .map { $0 ? "#" : "." }.joined()
                }.joined(separator: "\n")
            }

            for (rowOffset, line) in expected.enumerated() {
                for (columnOffset, character) in line.enumerated() {
                    let actual = grid[origin.row + rowOffset][origin.column + columnOffset]
                    let wanted = (character == "#")
                    if actual != wanted {
                        throw TestFailure(message: """
                        定位图案模块 (\(rowOffset),\(columnOffset)) 期望 \(wanted)，实际 \(actual)\
                        \(dump())
                        """)
                    }
                }
            }

            // Row and column 7 of the symbol are the separator, and must be light.
            for index in 0..<8 {
                try check(
                    !grid[origin.row + 7][origin.column + index],
                    "定位图案下方的分隔行应为浅色"
                )
                try check(
                    !grid[origin.row + index][origin.column + 7],
                    "定位图案右侧的分隔列应为浅色"
                )
            }
        }),

        ("静默区为空白", {
            let art = try checkUnwrap(TerminalQRCode.render(payload, quietZone: 3), "render 输出")
            let grid = try checkUnwrap(moduleGrid(from: art), "ASCII 画布解析")
            let origin = try checkUnwrap(findFinderOrigin(in: grid), "未找到定位图案")

            // At least the requested margin, even though the generator adds one of
            // its own — the assertion is "no less than asked for".
            try check(origin.row >= 3, "顶部静默区只有 \(origin.row) 个模块，少于要求的 3 个")
            try check(origin.column >= 3, "左侧静默区只有 \(origin.column) 个模块，少于要求的 3 个")

            for index in 0..<origin.row {
                try check(!grid[index].contains(true), "第 \(index) 行静默区内不应有深色模块")
            }
        }),

        ("inverted 样式为逐模块取反", {
            let normal = try checkUnwrap(
                TerminalQRCode.render(payload, quietZone: 1, style: .standard), "standard"
            )
            let inverted = try checkUnwrap(
                TerminalQRCode.render(payload, quietZone: 1, style: .inverted), "inverted"
            )
            let normalGrid = try checkUnwrap(moduleGrid(from: normal), "standard 解析")
            let invertedGrid = try checkUnwrap(moduleGrid(from: inverted), "inverted 解析")

            try checkEqual(normalGrid.count, invertedGrid.count, "行数")
            for row in normalGrid.indices {
                for column in normalGrid[row].indices where normalGrid[row][column] == invertedGrid[row][column] {
                    throw TestFailure(message: "模块 (\(row),\(column)) 未被取反")
                }
            }
        }),

        // Half-block pairing consumes two module rows per text line, so an odd
        // module count has to be padded or the last line comes up short.
        ("画布始终为矩形且行数为偶", {
            for text in ["a", "hi", payload, String(repeating: "x", count: 400)] {
                let art = try checkUnwrap(TerminalQRCode.render(text, quietZone: 2), "render 输出")
                let grid = try checkUnwrap(moduleGrid(from: art), "ASCII 画布解析")

                try checkEqual(grid.count % 2, 0, "模块行数应为偶数")
                for row in grid {
                    try checkEqual(row.count, grid[0].count, "各行宽度应一致")
                }
            }
        }),

        ("空内容也能生成合法画布", {
            let art = try checkUnwrap(TerminalQRCode.render(""), "render 输出")
            _ = try checkUnwrap(moduleGrid(from: art), "ASCII 画布解析")
        }),
    ]

    // MARK: - Helpers

    /// Locates the top-left finder pattern: the first dark module in raster order
    /// is, by construction, its outer corner. Nothing in a QR symbol sits above or
    /// to the left of it.
    static func findFinderOrigin(in grid: [[Bool]]) -> (row: Int, column: Int)? {
        for row in grid.indices {
            if let column = grid[row].firstIndex(of: true) {
                // Needs a full 7×7 plus separator to be assertable.
                guard row + 8 <= grid.count, column + 8 <= grid[row].count else { return nil }
                return (row, column)
            }
        }
        return nil
    }

    /// Reverses the half-block rendering: `█` is both halves, `▀` the top,
    /// `▄` the bottom, space neither.
    static func moduleGrid(from art: String) -> [[Bool]]? {
        var lines = art.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard let first = lines.first, !first.isEmpty else { return nil }

        let width = first.count
        var grid: [[Bool]] = []

        for line in lines {
            let characters = Array(line)
            guard characters.count == width else { return nil }

            var top: [Bool] = []
            var bottom: [Bool] = []
            for character in characters {
                switch character {
                case "█": top.append(true); bottom.append(true)
                case "▀": top.append(true); bottom.append(false)
                case "▄": top.append(false); bottom.append(true)
                case " ": top.append(false); bottom.append(false)
                default: return nil
                }
            }
            grid.append(top)
            grid.append(bottom)
        }
        return grid
    }

    /// Rebuilds a bitmap so a real detector can read the render. Rows are flipped
    /// because CGContext's origin is bottom-left while QR row 0 is the top.
    ///
    /// The grid is *not* necessarily square: half-block pairing needs an even row
    /// count, while the module count is usually odd (version 4 is 33×33), so the
    /// canvas ends up one row taller than it is wide. Ragged input returns nil
    /// rather than trapping, so a future regression reports a failure.
    static func image(from grid: [[Bool]], scale: Int = 8) -> CGImage? {
        guard let firstRow = grid.first, !firstRow.isEmpty else { return nil }

        let height = grid.count
        let width = firstRow.count

        guard let context = CGContext(
            data: nil,
            width: width * scale,
            height: height * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Light background first: a QR code is dark modules on a light field.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
        context.setFillColor(CGColor(gray: 0, alpha: 1))

        for row in 0..<height {
            let modules = grid[row]
            guard modules.count == width else { return nil }

            for column in 0..<width where modules[column] {
                context.fill(CGRect(
                    x: column * scale,
                    y: (height - 1 - row) * scale,
                    width: scale,
                    height: scale
                ))
            }
        }
        return context.makeImage()
    }
}
