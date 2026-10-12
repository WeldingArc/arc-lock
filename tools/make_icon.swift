// Renders Arc Lock's icon art: a brass arc as the shackle of a quiet navy lock.
// Usage: swift tools/make_icon.swift icon <out.png> [size]   — opaque, full-bleed app icon (iOS masks the corners)
//        swift tools/make_icon.swift mark <out.png> [size]   — transparent mark for the shield screen
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "icon"
let out = args.count > 2 ? args[2] : "icon.png"
let size = args.count > 3 ? Int(args[3])! : (mode == "icon" ? 1024 : 216)
let S = CGFloat(size)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let alphaInfo = mode == "icon" ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: alphaInfo.rawValue)!
func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)        // top-left origin
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

if mode == "icon" {
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(28, 38, 64), rgb(10, 14, 27)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: S / 2, y: 0), end: CGPoint(x: S / 2, y: S), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(200, 169, 106, 0.22), rgb(200, 169, 106, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S / 2, y: S * 0.30), startRadius: 0,
                           endCenter: CGPoint(x: S / 2, y: S * 0.30), endRadius: S * 0.55, options: [])
}

// Geometry in units of the canvas (the mark is centred, ~62% of the icon wide).
let unit = mode == "icon" ? S * 0.62 : S * 0.92
let cx = S / 2
let top = (S - unit) / 2 + (mode == "icon" ? S * 0.01 : 0)
let shackleW = unit * 0.56, shackleH = unit * 0.50
let stroke = unit * 0.095
let bodyW = unit * 0.80, bodyH = unit * 0.50, bodyR = unit * 0.13
let bodyY = top + unit * 0.47

// Shackle: an arc with straight legs going into the body.
let r = shackleW / 2
let arcCenter = CGPoint(x: cx, y: top + stroke / 2 + r)
let shackle = CGMutablePath()
shackle.move(to: CGPoint(x: cx - r, y: bodyY + bodyH * 0.2))
shackle.addLine(to: CGPoint(x: cx - r, y: arcCenter.y))
shackle.addArc(center: arcCenter, radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
shackle.addLine(to: CGPoint(x: cx + r, y: bodyY + bodyH * 0.2))
_ = shackleH

ctx.saveGState()
ctx.addPath(shackle)
ctx.setLineWidth(stroke)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let brass = CGGradient(colorsSpace: cs, colors: [rgb(233, 205, 146), rgb(200, 169, 106), rgb(150, 122, 70)] as CFArray,
                       locations: [0, 0.45, 1])!
ctx.drawLinearGradient(brass, start: CGPoint(x: cx - r, y: top), end: CGPoint(x: cx + r, y: bodyY + bodyH * 0.2), options: [])
ctx.restoreGState()

// Lock body: deep navy plate with a hairline brass rim and soft shadow.
let body = CGRect(x: cx - bodyW / 2, y: bodyY, width: bodyW, height: bodyH)
let bodyPath = CGPath(roundedRect: body, cornerWidth: bodyR, cornerHeight: bodyR, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: unit * 0.025), blur: unit * 0.06, color: rgb(0, 0, 0, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(24, 33, 57))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let plate = CGGradient(colorsSpace: cs, colors: [rgb(34, 45, 75), rgb(20, 27, 47)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(plate, start: CGPoint(x: cx, y: body.minY), end: CGPoint(x: cx, y: body.maxY), options: [])
ctx.restoreGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: unit * 0.006, dy: unit * 0.006), cornerWidth: bodyR, cornerHeight: bodyR, transform: nil))
ctx.setStrokeColor(rgb(200, 169, 106, 0.55))
ctx.setLineWidth(max(1, unit * 0.012))
ctx.strokePath()

// Keyhole: a small brass dot and slot.
let kh = CGPoint(x: cx, y: body.midY - bodyH * 0.06)
ctx.setFillColor(rgb(214, 186, 128))
ctx.fillEllipse(in: CGRect(x: kh.x - unit * 0.045, y: kh.y - unit * 0.045, width: unit * 0.09, height: unit * 0.09))
let slot = CGPath(roundedRect: CGRect(x: kh.x - unit * 0.018, y: kh.y, width: unit * 0.036, height: bodyH * 0.30),
                  cornerWidth: unit * 0.018, cornerHeight: unit * 0.018, transform: nil)
ctx.addPath(slot)
ctx.fillPath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out) (\(size)×\(size), \(mode))")
