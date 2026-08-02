#!/usr/bin/swift
// Generates the Parley app icon set (light, dark, tinted) at 1024x1024.
// Deterministic CoreGraphics drawing — rerun any time, no design tools needed.
//
//   swift make-icon.swift <output-dir>
//
// Concept: a single confident speech bubble, tilted 4 degrees for energy,
// carrying three rising dots (a conversation building). Warm coral-to-amber
// gradient background — deliberately NOT the indigo/violet every other AI
// app uses, so it stands out on a home screen full of them. Dark variant
// inverts to a deep charcoal with the gradient moved into the bubble; tinted
// variant is grayscale-on-transparent-black per Apple's guidance.

import AppKit
import CoreGraphics

let size = CGFloat(1024)

func makeContext() -> CGContext {
    CGContext(
        data: nil, width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        // No alpha in App Store icons: use noneSkipLast.
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func save(_ ctx: CGContext, _ path: String) {
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func gradient(_ ctx: CGContext, colors: [(CGFloat, CGFloat, CGFloat)], in rect: CGRect, vertical: Bool = true) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let cgColors = colors.map { CGColor(colorSpace: cs, components: [$0.0, $0.1, $0.2, 1])! }
    let grad = CGGradient(colorsSpace: cs, colors: cgColors as CFArray, locations: nil)!
    ctx.saveGState()
    ctx.clip(to: rect)
    if vertical {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    } else {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    ctx.restoreGState()
}

/// The bubble path: a rounded rect with a short tail at bottom-left,
/// centred at origin so it can be rotated before translation.
func bubblePath() -> CGPath {
    let w = CGFloat(560), h = CGFloat(430), r = CGFloat(120)
    let rect = CGRect(x: -w/2, y: -h/2, width: w, height: h)
    let path = CGMutablePath()
    path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
    // Tail: a soft triangle sweeping down-left from the bubble's lower-left.
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: -w/2 + 70, y: -h/2 + 8))
    tail.addQuadCurve(
        to: CGPoint(x: -w/2 - 60, y: -h/2 - 110),
        control: CGPoint(x: -w/2 + 30, y: -h/2 - 60)
    )
    tail.addQuadCurve(
        to: CGPoint(x: -w/2 + 200, y: -h/2 + 8),
        control: CGPoint(x: -w/2 + 90, y: -h/2 - 40)
    )
    tail.closeSubpath()
    path.addPath(tail)
    return path
}

/// Three rising dots inside the bubble: conversation gaining momentum.
func dotCenters() -> [(CGPoint, CGFloat)] {
    [
        (CGPoint(x: -150, y: -40), 56),
        (CGPoint(x: 0, y: -8), 62),
        (CGPoint(x: 155, y: 30), 68),
    ]
}

func drawBubble(_ ctx: CGContext, bubbleFill: (CGContext) -> Void, dotColor: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: size/2 + 20, y: size/2 + 30)
    ctx.rotate(by: 4 * .pi / 180)

    ctx.addPath(bubblePath())
    ctx.saveGState()
    ctx.clip()
    bubbleFill(ctx)
    ctx.restoreGState()

    ctx.setFillColor(dotColor)
    for (center, radius) in dotCenters() {
        ctx.fillEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
    }
    ctx.restoreGState()
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, 1])!
}

// ---- Light: warm coral -> amber background, white bubble, coral dots ----
do {
    let ctx = makeContext()
    gradient(ctx,
        colors: [(1.00, 0.42, 0.32), (1.00, 0.60, 0.22), (1.00, 0.72, 0.25)],
        in: CGRect(x: 0, y: 0, width: size, height: size))
    // Soft radial glow top-left for depth
    let glow = CGGradient(colorsSpace: cs,
        colors: [CGColor(colorSpace: cs, components: [1, 1, 1, 0.28])!,
                 CGColor(colorSpace: cs, components: [1, 1, 1, 0.0])!] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(glow,
        startCenter: CGPoint(x: 300, y: 800), startRadius: 0,
        endCenter: CGPoint(x: 300, y: 800), endRadius: 700, options: [])
    // Subtle drop shadow under the bubble
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26),
                  blur: 60,
                  color: CGColor(colorSpace: cs, components: [0.55, 0.15, 0.05, 0.35])!)
    drawBubble(ctx, bubbleFill: { c in
        c.setFillColor(rgb(1, 1, 1))
        c.fill(CGRect(x: -700, y: -700, width: 1400, height: 1400))
    }, dotColor: rgb(1.00, 0.48, 0.28))
    ctx.restoreGState()
    save(ctx, "\(outDir)/AppIcon.png")
}

// ---- Dark: charcoal background, gradient bubble, near-black dots ----
do {
    let ctx = makeContext()
    gradient(ctx,
        colors: [(0.10, 0.09, 0.11), (0.16, 0.13, 0.15)],
        in: CGRect(x: 0, y: 0, width: size, height: size))
    drawBubble(ctx, bubbleFill: { c in
        let grad = CGGradient(colorsSpace: cs,
            colors: [rgb(1.00, 0.45, 0.30), rgb(1.00, 0.68, 0.24)] as CFArray,
            locations: nil)!
        c.drawLinearGradient(grad,
            start: CGPoint(x: -300, y: 250),
            end: CGPoint(x: 300, y: -250), options: [])
    }, dotColor: rgb(0.10, 0.09, 0.11))
    save(ctx, "\(outDir)/AppIcon-dark.png")
}

// ---- Tinted: grayscale bubble on black; iOS applies the tint ----
do {
    let ctx = makeContext()
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    drawBubble(ctx, bubbleFill: { c in
        let grad = CGGradient(colorsSpace: cs,
            colors: [rgb(0.85, 0.85, 0.85), rgb(1, 1, 1)] as CFArray,
            locations: nil)!
        c.drawLinearGradient(grad,
            start: CGPoint(x: -300, y: 250),
            end: CGPoint(x: 300, y: -250), options: [])
    }, dotColor: rgb(0.05, 0.05, 0.05))
    save(ctx, "\(outDir)/AppIcon-tinted.png")
}
