import AppKit
import Foundation

// Generates the Relay Reader app icon from a small vector-style drawing.
// Run from the repository root: swift tool/generate_app_icon.swift

private let canvas: CGFloat = 2048
private let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

private let paper = NSColor(srgbRed: 0.969, green: 0.945, blue: 0.890, alpha: 1)
private let paperShade = NSColor(
  srgbRed: 0.878,
  green: 0.827,
  blue: 0.733,
  alpha: 1
)
private let ink = NSColor(srgbRed: 0.071, green: 0.165, blue: 0.137, alpha: 1)
private let forestTop = NSColor(
  srgbRed: 0.125,
  green: 0.306,
  blue: 0.251,
  alpha: 1
)
private let forestBottom = NSColor(
  srgbRed: 0.043,
  green: 0.137,
  blue: 0.114,
  alpha: 1
)
private let gold = NSColor(srgbRed: 0.902, green: 0.655, blue: 0.337, alpha: 1)
private let goldLight = NSColor(
  srgbRed: 0.984,
  green: 0.788,
  blue: 0.475,
  alpha: 1
)

// Coordinates use a top-left origin; the context is flipped once.

private func pagePath(left: Bool) -> NSBezierPath {
  let path = NSBezierPath()
  if left {
    path.move(to: NSPoint(x: 1004, y: 806))
    path.curve(
      to: NSPoint(x: 250, y: 900),
      controlPoint1: NSPoint(x: 760, y: 788),
      controlPoint2: NSPoint(x: 420, y: 822)
    )
    path.curve(
      to: NSPoint(x: 206, y: 968),
      controlPoint1: NSPoint(x: 218, y: 914),
      controlPoint2: NSPoint(x: 202, y: 940)
    )
    path.curve(
      to: NSPoint(x: 288, y: 1438),
      controlPoint1: NSPoint(x: 222, y: 1120),
      controlPoint2: NSPoint(x: 256, y: 1300)
    )
    path.curve(
      to: NSPoint(x: 390, y: 1496),
      controlPoint1: NSPoint(x: 300, y: 1478),
      controlPoint2: NSPoint(x: 338, y: 1500)
    )
    path.curve(
      to: NSPoint(x: 976, y: 1440),
      controlPoint1: NSPoint(x: 600, y: 1486),
      controlPoint2: NSPoint(x: 820, y: 1462)
    )
    path.curve(
      to: NSPoint(x: 1004, y: 1398),
      controlPoint1: NSPoint(x: 996, y: 1436),
      controlPoint2: NSPoint(x: 1006, y: 1420)
    )
    path.close()
  } else {
    path.move(to: NSPoint(x: 1044, y: 806))
    path.curve(
      to: NSPoint(x: 1798, y: 900),
      controlPoint1: NSPoint(x: 1288, y: 788),
      controlPoint2: NSPoint(x: 1628, y: 822)
    )
    path.curve(
      to: NSPoint(x: 1842, y: 968),
      controlPoint1: NSPoint(x: 1830, y: 914),
      controlPoint2: NSPoint(x: 1846, y: 940)
    )
    path.curve(
      to: NSPoint(x: 1760, y: 1438),
      controlPoint1: NSPoint(x: 1826, y: 1120),
      controlPoint2: NSPoint(x: 1792, y: 1300)
    )
    path.curve(
      to: NSPoint(x: 1658, y: 1496),
      controlPoint1: NSPoint(x: 1748, y: 1478),
      controlPoint2: NSPoint(x: 1710, y: 1500)
    )
    path.curve(
      to: NSPoint(x: 1072, y: 1440),
      controlPoint1: NSPoint(x: 1448, y: 1486),
      controlPoint2: NSPoint(x: 1228, y: 1462)
    )
    path.curve(
      to: NSPoint(x: 1044, y: 1398),
      controlPoint1: NSPoint(x: 1052, y: 1436),
      controlPoint2: NSPoint(x: 1042, y: 1420)
    )
    path.close()
  }
  return path
}

private func drawBackground(in rect: NSRect) {
  let path = NSBezierPath(rect: rect)
  let gradient = NSGradient(
    starting: forestTop,
    ending: forestBottom
  )!
  gradient.draw(in: path, angle: -55)

  NSGraphicsContext.saveGraphicsState()
  let glow = NSGradient(colors: [
    NSColor(srgbRed: 0.31, green: 0.54, blue: 0.44, alpha: 0.38),
    NSColor(srgbRed: 0.31, green: 0.54, blue: 0.44, alpha: 0.16),
    NSColor(srgbRed: 0.31, green: 0.54, blue: 0.44, alpha: 0),
  ])!
  glow.draw(
    fromCenter: NSPoint(x: 1024, y: 930),
    radius: 40,
    toCenter: NSPoint(x: 1024, y: 930),
    radius: 900,
    options: []
  )
  NSGraphicsContext.restoreGraphicsState()
}

private func drawPage(
  left: Bool,
  offsetY: CGFloat,
  fill: NSColor,
  stroke: NSColor?
) {
  let path = pagePath(left: left)
  path.transform(using: AffineTransform(translationByX: 0, byY: offsetY))
  fill.setFill()
  path.fill()
  if let stroke {
    stroke.setStroke()
    path.lineWidth = 5
    path.stroke()
  }
}

private func drawBook() {
  // A dark cover and soft shadow behind the open pages.
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
  shadow.shadowBlurRadius = 58
  shadow.shadowOffset = NSSize(width: 0, height: 34)
  shadow.set()
  NSColor(srgbRed: 0.03, green: 0.10, blue: 0.08, alpha: 0.78).setFill()
  for left in [true, false] {
    let cover = pagePath(left: left)
    cover.transform(using: AffineTransform(translationByX: 0, byY: 28))
    cover.fill()
  }
  NSGraphicsContext.restoreGraphicsState()

  // Stacked page edges give the open book thickness.
  for offset in [30.0, 21.0, 12.0] {
    for left in [true, false] {
      drawPage(
        left: left,
        offsetY: offset,
        fill: offset == 30
            ? ink.withAlphaComponent(0.34)
            : paperShade.withAlphaComponent(0.92),
        stroke: nil
      )
    }
  }

  // Cream page surfaces with a soft top-edge highlight.
  for left in [true, false] {
    drawPage(left: left, offsetY: 0, fill: paper, stroke: nil)
    let edge = pagePath(left: left)
    NSColor.white.withAlphaComponent(0.24).setStroke()
    edge.lineWidth = 4
    edge.stroke()
  }

  // Page rules. They sit quietly under the waveform and vanish at small sizes.
  NSGraphicsContext.saveGraphicsState()
  NSColor(srgbRed: 0.72, green: 0.63, blue: 0.49, alpha: 0.46).setStroke()
  for i in 0..<3 {
    let y = 1010 + CGFloat(i) * 82
    for left in [true, false] {
      let line = NSBezierPath()
      if left {
        line.move(to: NSPoint(x: 470, y: y))
        line.curve(
          to: NSPoint(x: 930, y: y - 34),
          controlPoint1: NSPoint(x: 610, y: y - 10),
          controlPoint2: NSPoint(x: 790, y: y - 26)
        )
      } else {
        line.move(to: NSPoint(x: 1114, y: y))
        line.curve(
          to: NSPoint(x: 1578, y: y - 34),
          controlPoint1: NSPoint(x: 1254, y: y - 10),
          controlPoint2: NSPoint(x: 1438, y: y - 26)
        )
      }
      line.lineWidth = 5
      line.stroke()
    }
  }
  NSGraphicsContext.restoreGraphicsState()

  // The gutter.
  let gutter = NSBezierPath(
    roundedRect: NSRect(x: 1004, y: 812, width: 40, height: 584),
    xRadius: 20,
    yRadius: 20
  )
  ink.withAlphaComponent(0.17).setFill()
  gutter.fill()
}

private func drawWaveform() {
  NSGraphicsContext.saveGraphicsState()
  let glow = NSShadow()
  glow.shadowColor = gold.withAlphaComponent(0.50)
  glow.shadowBlurRadius = 38
  glow.set()

  let bars: [(CGFloat, CGFloat, CGFloat)] = [
    (862, 1260, 930),
    (992, 1260, 670),
    (1124, 1260, 1030),
  ]
  for (x, bottom, top) in bars {
    let bar = NSBezierPath(
      roundedRect: NSRect(x: x, y: top, width: 62, height: bottom - top),
      xRadius: 31,
      yRadius: 31
    )
    let gradient = NSGradient(starting: goldLight, ending: gold)!
    gradient.draw(in: bar, angle: -90)
  }
  NSGraphicsContext.restoreGraphicsState()
}

private func renderIcon(size: CGFloat) -> NSData {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )!
  rep.size = NSSize(width: size, height: size)
  NSGraphicsContext.saveGraphicsState()
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = context
  context.cgContext.setAllowsAntialiasing(true)
  context.cgContext.setShouldAntialias(true)
  context.cgContext.translateBy(x: 0, y: size)
  context.cgContext.scaleBy(x: 1, y: -1)
  context.cgContext.scaleBy(x: size / canvas, y: size / canvas)

  drawBackground(in: NSRect(x: 0, y: 0, width: canvas, height: canvas))
  drawBook()
  drawWaveform()

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])! as NSData
}

private func writePNG(_ data: NSData, to url: URL) {
  try! data.write(to: url)
}

let master = renderIcon(size: 1024)

// Keep a 1024 master in the repo for future icon work.
let masterURL = output.appendingPathComponent(
  "assets/branding/app_icon_master.png"
)
try? FileManager.default.createDirectory(
  at: masterURL.deletingLastPathComponent(),
  withIntermediateDirectories: true
)
writePNG(master, to: masterURL)

print("Generated Relay Reader icon master.")
