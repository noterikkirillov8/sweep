// Draws the app icon (graphite body, a reclaim strip with its lit part and a needle) into the asset catalog.
// Run: swift scripts/make-icon.swift
import AppKit
let out = "Sweep/Resources/Assets.xcassets/AppIcon.appiconset"
func c(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: x*s, y: y*s, width: w*s, height: h*s), xRadius: r*s, yRadius: r*s)
    }
    // body
    c(0x1B1C1F).setFill(); rr(100, 100, 824, 824, 185).fill()
    c(0x34353A).setStroke(); let edge = rr(104, 104, 816, 816, 181); edge.lineWidth = 6*s; edge.stroke()
    // lit LED, top right
    c(0x5CEBD4).setFill(); NSBezierPath(ovalIn: NSRect(x: 740*s, y: 740*s, width: 44*s, height: 44*s)).fill()
    // recessed track
    c(0x121315).setFill(); rr(196, 420, 632, 184, 34).fill()
    c(0x2C2D31).setStroke(); let tr = rr(196, 420, 632, 184, 34); tr.lineWidth = 4*s; tr.stroke()
    // segments, fixed widths; the first three are lit
    let segs: [(CGFloat, UInt32, Bool)] = [(190, 0x5CEBD4, true), (110, 0x5CEBD4, true), (120, 0x2BB5A0, true),
                                           (80, 0x2A6E65, false), (60, 0x24524C, false)]
    var x: CGFloat = 220
    NSGraphicsContext.saveGraphicsState(); rr(196, 420, 632, 184, 34).addClip()
    for (w, hex, _) in segs { c(hex).setFill(); NSBezierPath(rect: NSRect(x: x*s, y: 444*s, width: w*s, height: 136*s)).fill(); x += w + 8 }
    NSGraphicsContext.restoreGraphicsState()
    // needle at the end of the lit part
    c(0xECEBE7).setFill(); rr(x_needle(segs) , 396, 22, 232, 8).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func x_needle(_ segs: [(CGFloat, UInt32, Bool)]) -> CGFloat {
    var x: CGFloat = 220
    for (w, _, lit) in segs where lit { x += w + 8 }
    return x - 4
}
var images: [String] = []
for (pt, sc) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let name = "icon_\(pt)x\(pt)@\(sc)x.png"
    try! draw(pt*sc).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    images.append(#"{"idiom":"mac","size":"\#(pt)x\#(pt)","scale":"\#(sc)x","filename":"\#(name)"}"#)
}
try! #"{"images":[\#(images.joined(separator: ","))],"info":{"version":1,"author":"xcode"}}"#.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
try! #"{"info":{"version":1,"author":"xcode"}}"#.write(toFile: "Sweep/Resources/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
