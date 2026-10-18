// Renders Arc Lock's phone-and-lock art in one of the five themes (Shared/Themes.swift has the same colors).
// Usage: swift tools/make_phone_icon.swift icon  <theme> <out.png> [size]  — opaque app icon (iOS masks the corners)
//        swift tools/make_phone_icon.swift mark  <theme> <out.png> [size]  — transparent mark for the block screen
//        swift tools/make_phone_icon.swift open  <theme> <out.png> [size]  — transparent mark, lock open (previews)
// Themes: navy graphite forest plum paper
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Look { let bgTop: UInt32, bgBottom: UInt32, screen: UInt32, accentLight: UInt32, accent: UInt32, accentDark: UInt32, cut: UInt32 }
let looks: [String: Look] = [
    "navy":     Look(bgTop: 0x1C2640, bgBottom: 0x0A0E1B, screen: 0x141C30, accentLight: 0xE9CD92, accent: 0xC8A96A, accentDark: 0x967A46, cut: 0x10172A),
    "graphite": Look(bgTop: 0x2A2D31, bgBottom: 0x0D0E10, screen: 0x1A1C1F, accentLight: 0xF2F4F7, accent: 0xC9CDD3, accentDark: 0x8D939B, cut: 0x15171A),
    "forest":   Look(bgTop: 0x1B3328, bgBottom: 0x08110C, screen: 0x13241C, accentLight: 0xD3E8C9, accent: 0xA8CBA0, accentDark: 0x6F9468, cut: 0x0F1C16),
    "plum":     Look(bgTop: 0x35213F, bgBottom: 0x110A15, screen: 0x21162A, accentLight: 0xF4CFC8, accent: 0xE0A9A0, accentDark: 0xA9726B, cut: 0x1A1121),
    "paper":    Look(bgTop: 0xFBF9F4, bgBottom: 0xE9E4D8, screen: 0xFFFFFF, accentLight: 0x4D6799, accent: 0x2F4A7A, accentDark: 0x1D2F52, cut: 0xF7F4EC),
]

let args = CommandLine.arguments
guard args.count >= 4, let look = looks[args[2]] else {
    print("usage: make_phone_icon.swift icon|mark|open <theme> <out.png> [size]"); exit(1)
}
let mode = args[1], out = args[3]
let size = args.count > 4 ? Int(args[4])! : (mode == "icon" ? 1024 : 216)
let S = CGFloat(size)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let opaque = mode == "icon"
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)        // top-left origin
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

if opaque {
    let bg = CGGradient(colorsSpace: cs, colors: [c(look.bgTop), c(look.bgBottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: S / 2, y: 0), end: CGPoint(x: S / 2, y: S), options: [])
    let glow = CGGradient(colorsSpace: cs, colors: [c(look.accent, 0.20), c(look.accent, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: S / 2, y: S * 0.42), startRadius: 0,
                           endCenter: CGPoint(x: S / 2, y: S * 0.42), endRadius: S * 0.52, options: [])
}

// Phone: an iPhone outline, ~70% of the icon tall.
let H = opaque ? S * 0.70 : S * 0.94
let W = H * 0.5
let cx = S / 2, cy = S / 2
let phone = CGRect(x: cx - W / 2, y: cy - H / 2, width: W, height: H)
let R = W * 0.24
let t = W * 0.075                                   // outline thickness
let phonePath = CGPath(roundedRect: phone.insetBy(dx: t / 2, dy: t / 2), cornerWidth: R - t / 2, cornerHeight: R - t / 2, transform: nil)

// screen: a faint panel inside the outline
ctx.saveGState()
ctx.addPath(phonePath)
ctx.setFillColor(c(look.screen, opaque ? 0.9 : 0.85))
ctx.fillPath()
ctx.restoreGState()

func accentGradient(from a: CGPoint, to b: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: [c(look.accentLight), c(look.accent), c(look.accentDark)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// outline, with a soft shadow on the icon
ctx.saveGState()
if opaque { ctx.setShadow(offset: CGSize(width: 0, height: S * 0.012), blur: S * 0.03, color: c(0x000000, look.bgTop > 0xA00000 ? 0.12 : 0.45)) }
ctx.addPath(phonePath)
ctx.setLineWidth(t)
ctx.replacePathWithStrokedPath()
ctx.clip()
accentGradient(from: CGPoint(x: phone.minX, y: phone.minY), to: CGPoint(x: phone.maxX, y: phone.maxY))
ctx.restoreGState()

// Dynamic Island
let island = CGRect(x: cx - W * 0.15, y: phone.minY + t + W * 0.07, width: W * 0.30, height: W * 0.085)
ctx.addPath(CGPath(roundedRect: island, cornerWidth: island.height / 2, cornerHeight: island.height / 2, transform: nil))
ctx.setFillColor(c(look.accent, 0.85))
ctx.fillPath()

// Lock, centred a little below the middle of the screen.
let open = mode == "open"
let bodyW = W * 0.52, bodyH = bodyW * 0.72
let bodyY = cy - bodyH * 0.12
let body = CGRect(x: cx - bodyW / 2, y: bodyY, width: bodyW, height: bodyH)
let shackleR = bodyW * 0.29
let shackleT = t * 0.95
let lift = open ? bodyW * 0.20 : 0
let shackleCenter = CGPoint(x: cx, y: bodyY - bodyW * 0.20 - lift)
let shackle = CGMutablePath()
shackle.move(to: CGPoint(x: cx - shackleR, y: bodyY + shackleT * 0.6 - (open ? lift : 0)))
shackle.addLine(to: CGPoint(x: cx - shackleR, y: shackleCenter.y))
shackle.addArc(center: shackleCenter, radius: shackleR, startAngle: .pi, endAngle: 0, clockwise: false)
shackle.addLine(to: CGPoint(x: cx + shackleR, y: open ? shackleCenter.y + bodyW * 0.05 : bodyY + shackleT * 0.6))
ctx.saveGState()
ctx.addPath(shackle)
ctx.setLineWidth(shackleT)
ctx.setLineCap(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
accentGradient(from: CGPoint(x: cx - shackleR, y: shackleCenter.y - shackleR), to: CGPoint(x: cx + shackleR, y: bodyY))
ctx.restoreGState()

let bodyPath = CGPath(roundedRect: body, cornerWidth: bodyW * 0.16, cornerHeight: bodyW * 0.16, transform: nil)
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
accentGradient(from: CGPoint(x: body.minX, y: body.minY), to: CGPoint(x: body.maxX, y: body.maxY))
ctx.restoreGState()

// keyhole, cut in the screen colour
let kh = CGPoint(x: cx, y: body.midY - bodyH * 0.08)
ctx.setFillColor(c(look.cut))
ctx.fillEllipse(in: CGRect(x: kh.x - bodyW * 0.075, y: kh.y - bodyW * 0.075, width: bodyW * 0.15, height: bodyW * 0.15))
ctx.addPath(CGPath(roundedRect: CGRect(x: kh.x - bodyW * 0.032, y: kh.y, width: bodyW * 0.064, height: bodyH * 0.32),
                   cornerWidth: bodyW * 0.032, cornerHeight: bodyW * 0.032, transform: nil))
ctx.fillPath()

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out) (\(size)×\(size), \(mode), \(args[2]))")
