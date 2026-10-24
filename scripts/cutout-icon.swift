// Removes a baked-in grey checkerboard around an icon tile and re-centres it on a 1024 macOS icon grid.
// usage: swift scripts/cutout-icon.swift generated.png Resources/AppIcon.png
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = src.width, h = src.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))

// Background = connected to the border and nearly grey (checkerboard and its shadow).
func isGrey(_ i: Int) -> Bool {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    return max(r, g, b) - min(r, g, b) < 28
}
var bg = [Bool](repeating: false, count: w * h)
var stack: [Int] = []
for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
while let i = stack.popLast() {
    if bg[i] || !isGrey(i) { continue }
    bg[i] = true
    let x = i % w, y = i / w
    if x > 0 { stack.append(i - 1) }
    if x < w - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - w) }
    if y < h - 1 { stack.append(i + w) }
}

// Feather: alpha = share of foreground pixels in a small box, then shrink by 1px to drop grey fringe.
let r = 2
var alpha = [Float](repeating: 0, count: w * h)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        var fg = 0, n = 0
        for dy in -r...r {
            for dx in -r...r {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                n += 1
                if !bg[yy * w + xx] { fg += 1 }
            }
        }
        let a = max(0, Float(fg) / Float(n) * 1.6 - 0.6)
        alpha[y * w + x] = min(1, a)
        if a > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
for i in 0..<(w * h) {
    let a = alpha[i]
    for c in 0..<3 { px[i * 4 + c] = UInt8(Float(px[i * 4 + c]) * a) }
    px[i * 4 + 3] = UInt8(a * 255)
}

let cut = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
// CG's origin is bottom-left; the bitmap rows are top-down.
let tile = cut.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

// Apple's macOS grid: 1024 canvas, 824 tile, centred, with a soft shadow.
let size = 1024, tileSize = 824.0
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let scale = tileSize / Double(max(tile.width, tile.height))
let tw = Double(tile.width) * scale, th = Double(tile.height) * scale
let rect = CGRect(x: (Double(size) - tw) / 2, y: (Double(size) - th) / 2 + 6, width: tw, height: th)
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
out.draw(tile, in: rect)

let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("tile \(maxX - minX + 1)×\(maxY - minY + 1) → \(Int(tw))×\(Int(th)) on \(size)×\(size)")
