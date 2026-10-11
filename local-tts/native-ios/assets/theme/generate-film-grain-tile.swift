// Generates `film-grain-tile.png` — the pre-rendered, seamlessly tileable
// grain `DesignSystem/Colors.swift`'s `SidebarTextureLayer` draws instead of
// rasterising ~84,000 ellipses in a `Canvas` on every appearance.
//
// Run from this directory:
//     swift generate-film-grain-tile.swift
//
// It reproduces `StaticFilmGrain`'s own `noise(column:row:)` and per-dot
// maths **exactly** — if either changes in Colors.swift, re-run this and
// commit the new PNG, or the bundled grain silently drifts from the
// procedural one still used by the two-tone variant.
//
// Two deliberate differences from the live Canvas:
//
//  1. `bottomBoost` is baked at its MAXIMUM (verticalProgress == 1), because
//     a tiled image cannot carry a position-dependent ramp. The view restores
//     the ramp by masking the tile with a vertical gradient running from
//     1/(1 + bottomBoost) at the top to 1 at the bottom, which reproduces the
//     original opacity curve.
//  2. Dots are drawn white, so the alpha channel alone carries the grain and
//     the view can tint it (`.renderingMode(.template)`) black over paper or
//     white over charcoal from this one asset.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Must match SidebarTextureLayer's StaticFilmGrain(...) call.
let spacing: CGFloat = 2
let intensity: Double = 1.08
let bottomBoost: Double = 0.55
let dotScale: CGFloat = 1

/// Tile edge in points. A multiple of `spacing` so the dot lattice itself
/// repeats cleanly; large enough that the repeat is invisible at the ~0.2
/// opacities this renders at under `.softLight`.
let tilePoints: CGFloat = 128
let scale: CGFloat = 2

// Verbatim from StaticFilmGrain.noise(column:row:). Note Swift puts `^` in
// AdditionPrecedence and `&*` in MultiplicationPrecedence, so the products
// bind tighter than the xors — same parse as the original.
func noise(column: Int, row: Int) -> UInt64 {
    var value =
        UInt64(0x6A09_E667_F3BC_C909)
        ^ UInt64(column) &* 73_856_093
        ^ UInt64(row) &* 19_349_663
    value ^= value >> 13
    value &*= 1_274_126_177
    return value ^ (value >> 16)
}

let pixelSize = Int(tilePoints * scale)
guard
    let context = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("could not create bitmap context\n".utf8))
    exit(1)
}

context.scaleBy(x: scale, y: scale)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

let cells = Int(tilePoints / spacing)
// verticalProgress is pinned to 1: the view re-applies the ramp as a mask.
let boostAtBottom = 1 + bottomBoost

var drawn = 0
for row in 0..<cells {
    for column in 0..<cells {
        let value = noise(column: column, row: row)
        let offsetX = CGFloat(value & 0xff) / 255 * spacing
        let offsetY = CGFloat((value >> 8) & 0xff) / 255 * spacing
        let diameter = (0.55 + CGFloat((value >> 16) & 0x3) * 0.18) * dotScale
        let opacity = min(
            (0.15 + Double((value >> 20) & 0x7) * 0.018) * intensity * boostAtBottom, 1)

        let x = CGFloat(column) * spacing + offsetX
        let y = CGFloat(row) * spacing + offsetY

        context.setAlpha(CGFloat(opacity))
        // A dot's random offset can push it past the tile's far edge, which
        // would clip and leave a visible seam when tiled. Drawing the same dot
        // again shifted back by one tile makes the wrap continuous.
        for wrapX in [CGFloat(0), -tilePoints] where x + diameter > tilePoints || wrapX == 0 {
            for wrapY in [CGFloat(0), -tilePoints]
            where y + diameter > tilePoints || wrapY == 0 {
                context.fillEllipse(
                    in: CGRect(
                        x: x + wrapX, y: y + wrapY, width: diameter, height: diameter))
            }
        }
        drawn += 1
    }
}

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not snapshot bitmap\n".utf8))
    exit(1)
}

let output = URL(fileURLWithPath: "film-grain-tile.png")
guard
    let destination = CGImageDestinationCreateWithURL(
        output as CFURL, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not create PNG destination\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write PNG\n".utf8))
    exit(1)
}

let attributes = try? FileManager.default.attributesOfItem(atPath: output.path)
let bytes = (attributes?[.size] as? Int) ?? 0
print(
    "wrote \(output.lastPathComponent): \(pixelSize)x\(pixelSize)px "
        + "(\(Int(tilePoints))pt @\(Int(scale))x), \(drawn) dots, \(bytes) bytes")
