// Renders the 1024 px app icon: an up/down arrow pair on a blue tile.
// Usage: swift icon.swift out.png
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1),
           ending: NSColor(red: 0.10, green: 0.78, blue: 0.70, alpha: 1))!.draw(in: tile, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .semibold)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
