#!/usr/bin/env swift
// Generates the 1024x1024 App Store icon.
// Style: Dark slate-to-sky gradient, frosted glass circle, light waveform.
// Usage: swift scripts/generate_app_icon.swift

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let outputPath = "Volocal/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

let topColor = NSColor(calibratedRed: 0.059, green: 0.090, blue: 0.165, alpha: 1.0)    // #0F172A
let bottomColor = NSColor(calibratedRed: 0.012, green: 0.412, blue: 0.631, alpha: 1.0)  // #0369A1
let frostAlpha: CGFloat = 0.18
let strokeAlpha: CGFloat = 0.3
let strokeWidth: CGFloat = 2.0
let circleRatio: CGFloat = 0.58
let waveformSize: CGFloat = 300
let waveformAlpha: CGFloat = 0.9

let image = NSImage(size: NSSize(width: size, height: size), flipped: false, drawingHandler: { (rect: NSRect) -> Bool in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    // Diagonal gradient background
    let gradientColors = [topColor.cgColor, bottomColor.cgColor] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 1.0]) else { return false }
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Subtle radial glow at center
    let glowColor = bottomColor.withAlphaComponent(0.3).cgColor
    if let glow = CGGradient(colorsSpace: colorSpace, colors: [glowColor, NSColor.clear.cgColor] as CFArray, locations: [0.0, 1.0]) {
        let center = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size * 0.55, options: [])
    }

    // Frosted glass circle
    let circleDiameter = size * circleRatio
    let circleRect = NSRect(x: (size - circleDiameter) / 2, y: (size - circleDiameter) / 2, width: circleDiameter, height: circleDiameter)
    let circlePath = NSBezierPath(ovalIn: circleRect)

    NSColor.white.withAlphaComponent(frostAlpha).setFill()
    circlePath.fill()

    // Inner highlight
    ctx.saveGState()
    ctx.addEllipse(in: circleRect)
    ctx.clip()
    let hlCenter = CGPoint(x: size / 2, y: size / 2 + circleDiameter * 0.2)
    let hlColor = NSColor.white.withAlphaComponent(frostAlpha * 0.4).cgColor
    if let hlGrad = CGGradient(colorsSpace: colorSpace, colors: [hlColor, NSColor.clear.cgColor] as CFArray, locations: [0.0, 0.6]) {
        ctx.drawRadialGradient(hlGrad, startCenter: hlCenter, startRadius: 0, endCenter: hlCenter, endRadius: circleDiameter * 0.5, options: [])
    }
    ctx.restoreGState()

    // Circle stroke
    NSColor.white.withAlphaComponent(strokeAlpha).setStroke()
    circlePath.lineWidth = strokeWidth
    circlePath.stroke()

    // Waveform symbol
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: waveformSize, weight: .light)
    guard let waveform = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig) else { return false }

    let wfSize = waveform.size
    let wfRect = NSRect(x: (size - wfSize.width) / 2, y: (size - wfSize.height) / 2, width: wfSize.width, height: wfSize.height)

    ctx.saveGState()
    if let cgImage = waveform.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        NSColor.white.withAlphaComponent(waveformAlpha).setFill()
        ctx.clip(to: wfRect, mask: cgImage)
        ctx.fill(wfRect)
    }
    ctx.restoreGState()

    return true
})

// Render to bitmap
let bitmapRep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
bitmapRep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    print("Failed to generate PNG")
    exit(1)
}

try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("App icon saved to \(outputPath)")
